# POST-FLIGHT: VERB-CAP-01

**Reviewer:** Adams
**Date:** 2026-05-30
**Baseline commit:** 816dbe2
**Branch:** stream/cap-capture-tunnel
**Smythe pre-flight verdict:** YELLOW (clear to proceed; genesis-event ambiguity resolved to option b)

---

## Final Status (Round 1): NOT-PASS

One test failure. BRR absent. Both block merge.

---

## Round-2 Verification — 2026-05-30

**Reviewer:** Adams
**Triggered by:** Bilby round-1 remediation (two CRITICAL fixes committed)

### Findings resolved

| # | Round-1 Severity | Resolution verified |
|---|---|---|
| 1 | CRITICAL | `captureRoundTrips` now uses field-by-field assertions + `abs(diff) < 1.0` for `filedAt`. Matches EstateVerbTests pattern. `swift test` exits 0, 455 passed. CLOSED. |
| 2 | CRITICAL | `docs/blast_radius/VERB_CAP_01_BLAST_RADIUS.md` committed as first commit of stream (`cd8bf31`). Contains baseline counts (441 Swift / 390 Rust), MUST_UPDATE files, INTENTIONALLY_LEFT justifications, RESCOPE=None. CLOSED. |
| 3 | WARNING | Rust `capture_tunnel` body ~55 lines. Bilby's justification accepted: six 3-line guard blocks mirror the Swift drawer `capture` validation style; extracting a `validate()` would add surface for no behavioral gain. WARNING RETAINED — non-blocking. |
| 4 | INFO | Mission file absent from disk (worktree teardown). Canonical spec in dispatch/docs repo. Non-blocking. RETAINED as INFO. |

### Scope check (round 2)

**Diff vs. BRR (8 files total, all additive):**

| File | BRR | Diff |
|---|---|---|
| `Sources/LocusKit/Frames.swift` | MUST_UPDATE | Present |
| `Sources/LocusKit/EstateVerbs.swift` | MUST_UPDATE | Present |
| `rust/src/frames.rs` | MUST_UPDATE | Present |
| `rust/src/estate_verbs.rs` | MUST_UPDATE | Present |
| `rust/src/lib.rs` | MUST_UPDATE | Present |
| `Tests/LocusKitTests/CaptureTunnelTests.swift` | NEW | Present |
| `rust/src/capture_tunnel_tests.rs` | NEW | Present |
| `docs/blast_radius/VERB_CAP_01_BLAST_RADIUS.md` | NEW | Present |

No unexpected files. No out-of-scope edits.

**MUST-NOT-MODIFY files:**

| File | Status |
|---|---|
| `Sources/LocusKit/Tunnel.swift` | UNTOUCHED |
| Cascade path (`addDrawerWithCascade` / `add_drawer_with_cascade`) | UNTOUCHED |
| `SubstrateLib` | UNTOUCHED |
| `docs/validation/**` | UNTOUCHED |

Cascade symbol appears only in doc comments of new code and in the BRR. Zero changes to executable cascade code.

### Prohibited patterns (round 2)

Grep of diff for `legacy`, `compat`, `bridge`, `shim`, `@available.*deprecated`, `TODO`, `FIXME`: **NONE**.

### Blast Radius Verification §9 (round 2)

**§9.1** BRR exists: PASS (`cd8bf31`).
**§9.2** Baseline counts recorded: PASS (441 Swift / 390 Rust, verified at 816dbe2).
**§9.3** All MUST_UPDATE files in diff: PASS (5/5 confirmed).
**§9.4** INTENTIONALLY_LEFT justifications: PASS — Tunnel.swift (no type/schema change), cascade path (reused not edited), SubstrateLib (used not changed), docs/validation (out of scope). Each names a specific reason.
**§9.5** Drift re-grep: `capture(_:TunnelCaptureFrame)` is a new overload; `capture_tunnel` is new. No pre-existing callers. No drift.
**§9.6** Prohibited patterns: NONE.

### Test Execution Verification §10 (round 2)

**Method: B (re-run) — engine code changed (EstateVerbs), new frame type.**

**Swift:**
```
Test run with 455 tests in 41 suites passed after 0.993 seconds.
EXIT: 0
```
455 = 441 baseline + 14 new. Count matches claim. PASS.

**Rust:**
```
test result: ok. 404 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
EXIT: 0
```
404 = 390 baseline + 14 new. Count matches claim. PASS.

---

## Final Status (Round 2): PASS

Clean. Ship it.

---

## Diff Scope Check

**Files claimed in blast radius (expected):**

| File | Status |
|------|--------|
| Sources/LocusKit/Frames.swift | MODIFIED — confirmed |
| Sources/LocusKit/EstateVerbs.swift | MODIFIED — confirmed |
| rust/src/frames.rs | MODIFIED — confirmed |
| rust/src/estate_verbs.rs | MODIFIED — confirmed |
| rust/src/lib.rs | MODIFIED — confirmed |
| Tests/LocusKitTests/CaptureTunnelTests.swift | NEW — confirmed (untracked) |
| rust/src/capture_tunnel_tests.rs | NEW — confirmed (untracked) |

**Files actually in diff:** 7 (5 modified, 2 new untracked). Matches blast radius exactly.

**MUST-NOT-MODIFY verification:**

| File | Status |
|------|--------|
| Sources/LocusKit/Tunnel.swift | UNTOUCHED — confirmed |
| Sources/LocusKit/DrawerStore.swift (cascade path) | UNTOUCHED — confirmed |
| rust/src/drawer_store_inmemory.rs | UNTOUCHED — confirmed |
| rust/src/tunnel.rs | UNTOUCHED — confirmed |
| docs/validation/** | UNTOUCHED — confirmed |

No scope violations. No out-of-scope edits. No bridges, shims, silenced warnings, or orphan deprecation markers in any new code.

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution |
|---|----------|---------|-----------|------------|
| 1 | CRITICAL | `swift test` exits 1. `captureRoundTrips` fails at `#expect(loaded == captured)`. `Date()` in `capture(_:TunnelCaptureFrame)` carries sub-millisecond precision; the ISO8601 round-trip through SQLite truncates to milliseconds. `loaded.filedAt != captured.filedAt` by nanoseconds. The printed `Description` renders identically — the mismatch is in the binary `timeIntervalSince1970` value. The drawer verb tests avoid this by checking individual fields; this test checks the whole struct. | CaptureTunnelTests.swift:68 | Two options: (A) truncate `now` to millisecond boundary before constructing `Tunnel` — `let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)` — matching the precision PersistenceKit stores; or (B) replace `#expect(loaded == captured)` with field-by-field checks that exclude `filedAt` (matching the drawer-test pattern). Option A is preferable — it makes the returned `Tunnel` and the persisted row agree on first read, not just in tests. |
| 2 | CRITICAL | No BRR exists. `docs/blast_radius/VERB_CAP_01_BLAST_RADIUS.md` is absent. Per §9.1, a missing blast radius report when the mission touches existing code blocks PASS. | docs/blast_radius/ | File `VERB_CAP_01_BLAST_RADIUS.md` before merge. Per blast-radius skill: record baseline test pass count (441 Swift / 390 Rust), list MUST_UPDATE files, list INTENTIONALLY_LEFT files with justifications. |
| 3 | INFO | Mission file `MISSION_VERB_CAP_01.md` does not exist on disk. `git status` shows it as an untracked path that was never written. Adams read the mission from the spawn prompt, so this did not block review. | docs/missions/inflight/ | Write and commit the mission file. The spawn prompt contains the full mission spec. Non-blocking on merge but the audit trail is incomplete without it. |

---

## Blast Radius Verification (§9)

**§9.1 BRR exists:** FAIL — `docs/blast_radius/VERB_CAP_01_BLAST_RADIUS.md` absent. CRITICAL.

**§9.2 Baseline test count recorded:** N/A (BRR absent — cannot verify).

**§9.3 Every MUST_UPDATE file in diff:** N/A (BRR absent). Independently verified: all 7 expected files are present and no unexpected files appear.

**§9.4 INTENTIONALLY_LEFT justifications:** N/A (BRR absent).

**§9.5 Re-run greps for drift:** No new stale call sites detected. `capture(_:TunnelCaptureFrame)` is a new overload; no existing callers to become stale. `capture_tunnel` is new; no existing callers.

**§9.6 Prohibited patterns:** None detected. No bridges, shims, `@available(*, deprecated)`, TODO/FIXME on changed symbols, or legacy/compat identifiers in the diff.

---

## Test Execution Verification (§10)

**Method: B (re-run) — mission changes engine code (EstateVerbs), data-model-adjacent (new frame type), risk is non-trivial.**

### Swift

Bilby's claim: exit 0, 455 tests passed.

My re-run:

```
Test "capture returns a well-formed tunnel and persists it" recorded an issue at
CaptureTunnelTests.swift:68:9: Expectation failed:
(loaded → Tunnel(id: "999115FC-...", filedAt: 2026-05-31 01:09:16 +0000, ...))
== (captured → Tunnel(id: "999115FC-...", filedAt: 2026-05-31 01:09:16 +0000, ...))

Test run with 455 tests in 41 suites failed after 1.644 seconds with 1 issue.
EXIT: 1
```

**Status: CRITICAL. Tests do not pass. Bilby's "exit 0" claim is false.**

The failure is `captureRoundTrips` — one test out of 14 new Swift tests. The other 13 pass. The root cause is `Date()` nanosecond precision vs ISO8601 millisecond storage. This is a test-correctness bug in new code, not a pre-existing break.

### Rust

Bilby's claim: exit 0, 404 tests passed.

My re-run:

```
test result: ok. 404 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.02s
EXIT: 0
```

**Status: PASS. Confirmed exit 0, 404 tests. Count matches claim (390 baseline + 14 new).**

---

## Swift-Rust Parity Check

14 Swift tests / 14 Rust tests. Case-for-case mirror confirmed:

| Swift (`CaptureTunnelTests.swift`) | Rust (`capture_tunnel_tests.rs`) |
|------------------------------------|----------------------------------|
| `captureRoundTrips` | `capture_round_trips` |
| `captureZeroBitmaps` | `capture_zero_bitmaps` |
| `byteIdenticalToCascade` | `byte_identical_to_cascade` |
| `endpointsResolve` | `endpoints_resolve` |
| `roomLevelEndpoints` | `room_level_endpoints` |
| `recallableFromSource` | `recallable_from_source` |
| `recallableToTarget` | `recallable_to_target` |
| `kindHandling` | `kind_default_and_round_trip` |
| `rejectsEmptySourceWing` | `rejects_empty_source_wing` |
| `rejectsEmptySourceRoom` | `rejects_empty_source_room` |
| `rejectsEmptyTargetWing` | `rejects_empty_target_wing` |
| `rejectsEmptyTargetRoom` | `rejects_empty_target_room` |
| `rejectsEmptyLabel` | `rejects_empty_label` |
| `rejectsEmptyAddedBy` | `rejects_empty_added_by` |

Parity is complete. The Rust `byte_identical_to_cascade` uses a pinned `NOW: i64 = 1_700_000_000` (epoch seconds), which is why it passes: the integer-millisecond round-trip is lossless. The Swift equivalent calls `Date()`, which is why it fails.

---

## Byte-Identity-to-Cascade Claim (Duty 3)

**Swift cascade path** (`DrawerStore.addDrawerWithCascade`, lines 257-268):
```swift
let tunnel = Tunnel(
    id: "supersedes:\(d.id):\(priorID)",
    sourceWing: d.wing, sourceRoom: d.room, sourceDrawerId: d.id,
    targetWing: priorWing, targetRoom: priorRoom, targetDrawerId: priorID,
    label: "supersedes", kind: .supersedes,
    addedBy: d.addedBy, filedAt: d.filedAt
)
_ = try await storage.rowStore.insert(table: "tunnels", values: Self.tunnelValues(tunnel))
```

Bitmap defaults: `adjectiveBitmap: Int64 = 0`, `operationalBitmap: Int64 = 0`, `provenanceBitmap: Int64 = 0` — Tunnel's designated initializer defaults confirmed (Tunnel.swift lines 107-109).

**Swift standalone path** (`EstateVerbs.swift`):
```swift
let tunnel = Tunnel(
    id: UUID().uuidString,
    sourceWing: frame.sourceWing, ...,
    kind: frame.kind,
    addedBy: frame.addedBy, filedAt: now
)
try await store.addTunnel(tunnel)
```

`addTunnel` calls `storage.rowStore.insert(table: "tunnels", ...)` — same underlying insert path. No audit event in either path. Bitmaps: both use all-zero defaults. **Byte-identity claim is structurally correct**: same columns, same defaults, same insert path, no audit side-effects.

The `byteIdenticalToCascade` Swift test correctly verifies this by comparing bitmap, label, kind, endpoints, tombstonedAt, and removedByBatch field-for-field. It deliberately excludes `id` (different by design — cascade uses deterministic `"supersedes:..."` ID, standalone uses UUID) and `filedAt` (different times). This exclusion is intentional and correct.

**Rust cascade path** (`drawer_store_inmemory.rs`, lines 375-390): identical structure. `Tunnel::new(...)` then `tunnel.kind = TunnelKind::Supersedes` then `row_store.insert(T_TUNNELS, tunnel_values(&tunnel))`. All-zero bitmap defaults. Same field set.

**Rust standalone path** (`estate_verbs.rs`, `capture_tunnel`): `Tunnel::new(...)` then `tunnel.kind = frame.kind` then `self.store.add_tunnel(&tunnel)` which calls `row_store.insert(T_TUNNELS, ...)`. Byte-identical construction confirmed.

The one asymmetry: Rust sets `kind` as a post-construction mutation (`tunnel.kind = frame.kind`) rather than in the `new()` call, which doesn't have a `kind` parameter. This matches the cascade pattern exactly. No concern.

---

## Complexity Check

New functions in Swift:
- `capture(_ frame: TunnelCaptureFrame)` — 35 lines including guards and comments. Under 40. Clear.
- `_peekTunnel`, `_tunnelsFrom`, `_tunnelsTo` — 1-2 lines each. Clear.

New functions in Rust:
- `capture_tunnel` — 55 lines including guards and comments. Over 40.

The Rust `capture_tunnel` is over the 40-line threshold. The length is entirely guards (6 validation checks, each 3 lines) plus the construction block. The guards mirror the Swift version exactly and there is no extractable sub-function that would improve clarity. **WARNING per complexity check protocol (non-blocking). Bilby should add an inline comment explaining the length or refactor the validation guards into a `TunnelCaptureFrame::validate()` method.**

---

## Summary

Two CRITICAL findings block merge:

1. `swift test` exits 1. `captureRoundTrips` fails due to `Date()` nanosecond precision vs ISO8601 millisecond truncation. Fix the precision at the point `now` is created, or replace the struct-equality check with field-by-field checks. The bug is in the test, not the implementation — but a broken test is a broken test.

2. No BRR filed. `docs/blast_radius/VERB_CAP_01_BLAST_RADIUS.md` must exist before merge.

Everything else is clean: scope correct, MUST-NOT-MODIFY files untouched, no prohibited patterns, parity complete (14+14), byte-identity claim structurally sound, Rust tests exit 0 / 404 confirmed.

Fix finding #1 and file the BRR. Then re-run. If those two come back clean, this is a PASS.

---

## Adams Learning Note — VERB-CAP-01

**Mission:** Standalone tunnel capture verb
**Files reviewed:** Frames.swift, EstateVerbs.swift, frames.rs, estate_verbs.rs, lib.rs, CaptureTunnelTests.swift, capture_tunnel_tests.rs
**Date:** 2026-05-30

### Patterns observed

- **Date precision mismatch in round-trip tests:** `Date()` in Swift captures nanoseconds; ISO8601 with `.withFractionalSeconds` stores milliseconds. Struct equality fails when `filedAt` is set from `Date()` and then compared to the stored+loaded value. Recurrence: first time seen in this codebase. Future signal: any test that uses `#expect(storedEntity == returnedEntity)` where the entity has a `Date` field set from `Date()` (not from a pinned epoch) will fail this way. Pattern to watch: drawer tests avoid it by only checking specific fields. The Rust side avoids it by using a pinned `i64`. New Swift tests that want to check full struct equality should either pin the time or truncate to millisecond before storing.

- **BRR missing at merge time:** Bilby implemented correctly but did not file the blast radius report. This is a process compliance issue, not an implementation issue. Pattern recurs when there is no BRR step in the mission template's checklist or when the agent is working in a working-tree (not-yet-committed) context and the BRR step is treated as a post-commit task.

### Surprises

- The Rust `byte_identical_to_cascade` test passed despite the same logical pattern as the failing Swift test — because Rust uses `i64` epoch-seconds (not a `Date` object), so there is no sub-second precision to lose. The asymmetry in test approach between Swift and Rust masked the bug.

### File-specific notes

- `CaptureTunnelTests.swift:68`: `#expect(loaded == captured)` — the only full-struct equality check on a tunnel with a live `Date()` in the test suite. High recurrence risk if this pattern is copied to future tunnel or association tests.

### Systemic flags

- None. The `Date()` precision issue is specific to test correctness, not architecture.
