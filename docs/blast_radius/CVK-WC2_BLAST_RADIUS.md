# Blast Radius Report — CVK-WC2

**Baseline:** swift test (ConvergenceKitFederation) pass count at mission start: 83  
**Mission:** CVK-WC2 — Federation durable _fed_outbox both legs  
**Codegraph:** unavailable — grep-only (no codegraph index in session)

## Symbols being changed

### Symbol 1: `FederationStateActor.pendingOutbound`
**Change class:** removal — in-memory `[TableChange]` array replaced by durable `_fed_outbox` table  
**Scope:** internal (actor-isolated)

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 255 | grep | MUST_UPDATE | Declaration site — removed |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 344 | grep | MUST_UPDATE | `disable()` removes all — replaced with durable leave-in-place |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 398,401 | grep | MUST_UPDATE | `recordOutbound` appends — replaced with durable outbox append |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 444,445 | grep | MUST_UPDATE | `push()` drains — replaced with `FedOutboxStore.readBatch` |

**Summary:** MUST_UPDATE: 4 sites (all in same file). INTENTIONALLY_LEFT: 0. RESCOPE_REQUIRED: 0.

---

### Symbol 2: `FederationStateActor.ensureFedSyncMetaTable`
**Change class:** additive — v4 → v5, adds `_fed_outbox` table declaration + migration  
**Scope:** internal

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 963 | grep | MUST_UPDATE | Function body — add v5 table + migration |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 1036–1061 | grep | MUST_UPDATE | `SchemaDeclaration(version:4)` → `version:5` + new migration |

**Summary:** MUST_UPDATE: 2 sites (same file). RESCOPE_REQUIRED: 0.

---

### Symbol 3: `Relay.send(to:message:)` protocol method
**Change class:** signature change — non-throwing → `throws`  
**Scope:** public

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 213 | grep | MUST_UPDATE | Protocol declaration — add `throws` |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 227 | grep | MUST_UPDATE | `FederationRelay.send` conformance — add `throws` to signature |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 548 | grep | MUST_UPDATE | `push()` call site — wrap in `try` |

**Summary:** MUST_UPDATE: 3 sites (same file). RESCOPE_REQUIRED: 0.

WHY making Relay.send throw: the mission spec requires a "push-failure-retains (throwing relay)" test. The only way to test that outbox entries survive a relay failure is to have a Relay conformer that throws. The protocol must support throws for this contract. In-process relay never actually throws; the protocol change is additive for existing conformers.

---

### Symbol 4: Rust `EngineState.outbox` (in-memory `Arc<Mutex<Vec<SyncRecord>>>`)
**Change class:** removal — in-memory outbox replaced by durable `_fed_outbox` table  
**Scope:** private (struct field)

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `rust/src/federation.rs` | 293–300 | grep | MUST_UPDATE | `EngineState.outbox` field declaration — removed |
| `rust/src/federation.rs` | 350 | grep | MUST_UPDATE | `EngineState` init in `FederationSyncEngine::new` |
| `rust/src/federation.rs` | 379–382 | grep | MUST_UPDATE | `enqueue()` method — write to durable table |
| `rust/src/federation.rs` | 444,480–482 | grep | MUST_UPDATE | `start_observers` worker closure captures `outbox` — replace with storage write |
| `rust/src/federation.rs` | 588 | grep | MUST_UPDATE | `disable()` clears outbox — remove (durable leave-in-place) |
| `rust/src/federation.rs` | 602 | grep | MUST_UPDATE | `push()` drains `outbox` — replace with `fed_outbox_read_batch` |

**Summary:** MUST_UPDATE: 6 sites (same file). RESCOPE_REQUIRED: 0.

---

### Symbol 5: Rust `Relay::send_to` trait method
**Change class:** signature change — returns unit → returns `Result<(), String>`  
**Scope:** public (trait)

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `rust/src/federation.rs` | 216 | grep | MUST_UPDATE | Trait definition |
| `rust/src/federation.rs` | 251–265 | grep | MUST_UPDATE | `FederationRelay::send_to` implementation — return `Ok(())` |
| `rust/src/federation.rs` | 647 | grep | MUST_UPDATE | `push()` call site — handle `Err` |

**Summary:** MUST_UPDATE: 3 sites (same file). RESCOPE_REQUIRED: 0.

---

### Symbol 6: `ensure_fed_sync_meta_table` (Rust)
**Change class:** additive — v4 → v5, adds `_fed_outbox` table  
**Scope:** private

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `rust/src/federation.rs` | 1442–1471 | grep | MUST_UPDATE | Schema declaration v4→v5, new table, new migration |

**Summary:** MUST_UPDATE: 1 site.

---

## New symbols (purely additive — no blast radius)

- `FedOutboxEntry` struct (Swift) — new file `FedOutboxStore.swift`
- `FedOutboxStore` enum (Swift) — new file `FedOutboxStore.swift`
- `FED_OUTBOX_TABLE` const (Rust) — additive constant
- `FedOutboxEntry` struct (Rust) — additive
- `fed_outbox_append`, `fed_outbox_read_batch`, `fed_outbox_confirm`, `fed_outbox_drain_leftovers` (Rust) — additive helpers
- `FederationDurableOutboxTests.swift` (Swift) — new test file
- `federation_durable_outbox_tests.rs` (Rust) — new test file

---

## SPEC changes (non-code)

| File | Section | Classification | Change |
|---|---|---|---|
| `docs/reference/CONVERGENCEKIT_SPEC.md` | B-11 | MUST_UPDATE | Remove claim that Federation uses in-memory array; note _fed_outbox added WC2 |
| `docs/reference/CONVERGENCEKIT_SPEC.md` | C-13 | MUST_UPDATE | Extend "CloudKit-specific" to include Federation (both backends now durable) |
| `docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md` | WC2 row | MUST_UPDATE | Mark WC2 done |

---

## Overall summary

- MUST_UPDATE code sites: 19 (all in `FederationSyncEngine.swift` or `federation.rs`)
- New files: 4 (2 Swift, 2 Rust)
- RESCOPE_REQUIRED: 0 — blast radius is contained within the ConvergenceKit package
- No cross-product surface affected
- No CriticalPrimitive table entries triggered
