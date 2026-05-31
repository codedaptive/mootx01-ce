# Smythe Pre-flight: VERB-REA-01

## Status

YELLOW — clear to proceed with three items Bilby must verify before writing store code.

---

## Status details

- **Blast radius:** Mission file table lists 6 files. Real blast radius is 6–8 files — the conditional
  DrawerStore additions are real and required; both trait and impl must add a `reanchorGated` method
  absent from the current store. No unexpected symbol collisions.
- **Prior art:** No conflicting prior art. No half-built `reanchor` implementation exists in either
  leg. The stub is clean and correctly positioned at the declared line anchors.
- **Environment:** Branch `stream/rea-reanchor-drawer` active, head `816dbe2` (main merge of
  TASK-MXC-2026-0002). Baseline tests clean — Swift 441 passed / Rust 390 passed, both zero failures.
- **Dependencies:** None listed. Mission declares parallel-safe with VERB-REC-01, VERB-MUT-01,
  VERB-WEX-01, VERB-CAP-01, VERB-LRN-01 with serialised fan-in merges. Confirmed no shared symbol
  conflicts with those stubs (all are independent verb slots in EstateVerbs.swift).

---

## Blockers

None hard. Three YELLOW items require Bilby to look before writing — they are solvable and the path
is clear, but the wrong assumption on any of them produces a broken commit.

---

## Verified findings

### 1. Stub line anchors — confirmed exact

**Swift `EstateVerbs.swift:379`:**
```swift
func reanchor(
    rowID: RowID,
    toRoom: RoomID? = nil,
    toLattice: LatticeAnchor? = nil
) async throws {
    throw LocusKitError.invalidContent("reanchor not yet implemented")
}
```
Line 379 confirmed. Signature matches mission exactly.

**Rust `estate_verbs.rs:419`:**
```rust
pub fn reanchor(
    &self,
    _row_id: &str,
    _to_room: Option<&str>,
    _to_lattice: Option<crate::estate_types::LatticeAnchor>,
) -> Result<(), LocusKitError> {
    Err(LocusKitError::InvalidContent("reanchor not yet implemented".to_string()))
}
```
Line 419 confirmed. Signature matches mission exactly.

**Rust stub test `estate_verbs.rs:656`:**
```rust
fn reanchor_stub_returns_invalid_content() { ... }
```
Line 656 confirmed. This test must be REPLACED by the real conformance suite (it asserts
`InvalidContent` — exactly what will no longer be true after implementation).

---

### 2. The empty-reanchor contract

**GLK guard (VerbSurface.swift:166-169):**
```swift
guard frame.toRoom != nil || frame.toLattice != nil else {
    throw VerbError.emptyReanchor(rowID: frame.rowID)
}
```
The GLK guard fires BEFORE dispatch. An empty reanchor never reaches `Estate.reanchor`.

**LocusKit's own guard — required or not?**

The existing pattern for `expunge` shows that LocusKit's verb body adds its own guard even though
GLK also guards first (belt-and-suspenders — the LocusKit body cannot assume a GLK wrapper is
present). The mission instructs "empty -> emptyReanchor error." However, `LocusKitError` has no
`.emptyReanchor` case — that case lives on `VerbError` (GLK's error type). LocusKit must throw
a `LocusKitError`, which means the inner guard should throw
`LocusKitError.invalidContent("reanchor requires toRoom or toLattice")` — NOT `VerbError.emptyReanchor`.
The GLK `remap` function catches the `LocusKitError.invalidContent` and re-raises it as
`VerbError.notSupportedByEstate` if the reanchor stub were still in place; once implemented, the
guard in LocusKit throws `invalidContent` and GLK's `remap` converts it. Verify `remap` logic and
confirm this is the correct error. Do not try to throw `VerbError` from inside LocusKit.

---

### 3. CRITICAL — cross-package test MUST_UPDATE (not in mission's file list)

**`GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift:169`**
```swift
func testReanchorRoundTripSurfacesNotSupported() async throws {
    // ... asserts VerbError.notSupportedByEstate("reanchor")
}
```
This assertion will FAIL once `Estate.reanchor` is implemented. The stub currently throws
`LocusKitError.invalidContent("reanchor not yet implemented")` which GLK remaps to
`VerbError.notSupportedByEstate`. A real implementation will NOT throw that error — it will succeed
(or throw `emptyReanchor` / `drawerNotFound`). The test is now a lie.

**Precedent confirmed:** `testWithdrawRoundTrip` (VerbSurfaceTests.swift:111) is a real round-trip
test; the `withdraw`-stub-surfaces-notSupported equivalent was replaced when `withdraw` was
implemented. Same surgery is required here.

**Classification: MUST_UPDATE — outside the mission's declared file list.**

The mission's blast radius table does not include `GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift`.
It must be added. The test at line 169 must be rewritten from "assert notSupportedByEstate" to a
real round-trip: capture a row, reanchor it to a new lattice, recall and assert the anchor moved.
The guard test at line 156 (`testReanchorEmptyRaisesGuard`) is correct and stays as-is.

**If Bilby does not update this test, the GLK test suite will be red after this mission. That is
a regression introduced by this mission, not pre-existing debt. This file must be in the commit.**

---

### 4. GLK test suite baseline — confirmed currently GREEN

`VerbSurfaceTests.swift` compiles and passes on this branch. The `ProposalKind` ambiguity noted in
a prior branch note does NOT appear on `stream/rea-reanchor-drawer` — the test file imports are
clean at the head commit. Verified by reading the import block (AriaLexiconLib, LocusKit,
PersistenceKit, PersistenceKitInMemory, GeniusLocusKit). No blocking compile issue in the baseline.

**Consequence:** breaking `testReanchorRoundTripSurfacesNotSupported` without fixing it is a true
regression on a currently-green suite. Bilby must own the fix.

---

### 5. DrawerStore placement-update path — MUST ADD, not conditional

**No `reanchorGated` or room/lattice update method exists** in either `DrawerStore.swift` or
the Rust `DrawerStore` trait + `InMemoryDrawerStore` impl. The mission marks this "conditional" but
the condition is always true — the method is absent and must be added.

**Pattern to follow:**

The `expungeGated` path in `DrawerStore.swift` (line 587) is the closest canonical:
1. Read the current row inside a transaction (for prior bitmaps).
2. Build a `BitmapFields` prior snapshot.
3. Read the current anchor from `row["udcCode"]`.
4. Call `AuditGate.admit(...)` with `verb: .mutate` — there is NO `RowVerb.reanchor` case.
   `RowVerb` is a closed enum with 12 cases (capture, observe, mutate, retract, promote, reject,
   supersede, decay, expire, contest, resolveContest, tombstone). Reanchor uses `.mutate`
   (the active→active self-loop) for the audit gate verb; the anchor change is expressed via
   `afterLatticeAnchor` differing from `priorLatticeAnchor`.
5. Update `udcCode` (and optionally `room`) in the projection row.
6. Append the sealed audit event.
7. For room change: also update the `room` column in the same transaction.

**SubstrateLib reference (`Verbs.swift:170`, `glref-rust-verbs.rs:263`)** uses its own internal
`appendAudit(verb: "reanchor", ...)` string — that is SubstrateLib's own flat audit log, not
`AuditGate.admit`. LocusKit uses `AuditGate.admit`. Use `.mutate` as the RowVerb. The
`beforeAnchor / afterAnchor` parameters on `AuditGate.admit` carry the anchor delta.

**Drawer model fields confirmed:**
- `room: String` at `Drawer.swift:58` — present, updateable.
- `udcCode: String` — the LatticeAnchor source column; confirmed in `DrawerStore.swift:527`
  (`SubstrateTypes.LatticeAnchor.udc(Self.string(row["udcCode"]))`).
- `LatticeAnchor` is passed as `SubstrateTypes.LatticeAnchor.udc(string)` throughout the store.

**Rust counterpart:** `drawer_store_inmemory.rs` has `read_drawer_udc` helper at line 422.
Neither `drawer_store.rs` trait nor the inmemory impl has a `reanchor_gated` method. Both must
be added (trait default + impl override, same pattern as `expunge_gated`).

---

### 6. SubstrateLib reference — confirmed use-only

`packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift:170` and
`packages/libs/SubstrateLib/rust/glref-rust-verbs.rs:263` are the canonical before/after audit
pattern to READ and mirror. Both are MUST-NOT-MODIFY. The SubstrateLib reference uses its own
internal audit mechanism (not AuditGate). LocusKit mirrors the semantic pattern (read prior anchor,
apply new anchor, emit audit with before/after anchor pair) but routes through `AuditGate.admit`
with `verb: .mutate`, as every other LocusKit write path does.

---

## Baseline test counts

| Suite | Count | Status |
|---|---|---|
| Swift `swift test` | **441 passed, 0 failed** | GREEN |
| Rust `cargo test --lib` | **390 passed, 0 failed** | GREEN |

Counts at mission start. Record these in the Test Verification Log before Part 1.

---

## Verified blast radius — 8 files (vs mission's 6 declared)

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Sources/LocusKit/EstateVerbs.swift` | yes | implement reanchor stub (~20 lines) | MUST_UPDATE |
| `rust/src/estate_verbs.rs` | yes | Rust mirror + replace stub test | MUST_UPDATE |
| `Sources/LocusKit/DrawerStore.swift` | yes (conditional) | add `reanchorGated` method | MUST_UPDATE (not conditional — always absent) |
| `rust/src/drawer_store.rs` | yes (conditional) | add `reanchor_gated` trait default | MUST_UPDATE |
| `rust/src/drawer_store_inmemory.rs` | **no** | implement `reanchor_gated` | MUST_UPDATE (required by drawer_store.rs change) |
| `Tests/LocusKitTests/ReanchorTests.swift` | yes (CREATE) | conformance suite | MUST_UPDATE |
| `rust/src/reanchor_tests.rs` | yes (CREATE) | Rust mirror conformance suite | MUST_UPDATE |
| `GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift` | **no** | replace `testReanchorRoundTripSurfacesNotSupported` | MUST_UPDATE (cross-package, outside declared list) |

---

## Bilby's stated approach

*[To be written by Bilby before proceeding. 2–4 sentences: which files first, which pattern,
what is NOT being done.]*

**Assessment:** Pending Bilby's statement.

---

## Actions (proceeding)

1. Confirm `remap` function in `VerbSurface.swift` handles `LocusKitError.invalidContent` from a
   real (non-stub) reanchor body correctly — ensure the inner empty-guard throws
   `LocusKitError.invalidContent`, not `VerbError`.
2. Add `reanchorGated` to Swift `DrawerStore.swift` following `expungeGated` structure. Use
   `verb: .mutate` for the `AuditGate.admit` call; pass `priorLatticeAnchor` (current anchor) and
   `afterLatticeAnchor` (new anchor). Update both `udcCode` and (when provided) `room` columns in
   the projection row, same transaction as the audit event append.
3. Add `reanchor_gated` trait default to `drawer_store.rs` and implement in `drawer_store_inmemory.rs`.
4. Implement `Estate.reanchor` in `EstateVerbs.swift`: guard empty (both nil → `invalidContent`);
   look up row (absent → `drawerNotFound`); call `store.reanchorGated(...)`. Mirror in Rust.
5. Replace `reanchor_stub_returns_invalid_content` in `estate_verbs.rs:656` with the real
   conformance tests (or move to `reanchor_tests.rs`).
6. Write `ReanchorTests.swift` (CREATE) + `reanchor_tests.rs` (CREATE). Cover: room move; lattice
   move; empty reanchor error; not-found; audit entry written; bitmaps otherwise unchanged.
7. Rewrite `testReanchorRoundTripSurfacesNotSupported` in
   `GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift` to a real round-trip
   (capture, reanchor, recall, assert anchor moved). Keep `testReanchorEmptyRaisesGuard` as-is.
8. `swift test` green (≥441 + new tests); `cargo test --lib` green (≥390 + new tests); zero warnings.

---

## Decision needed

None required from Bob. The path is clear. YELLOW items above are informational — Bilby must look
before writing but no rescope is needed.

Bilby's stated approach field above must be filled before coding starts.
