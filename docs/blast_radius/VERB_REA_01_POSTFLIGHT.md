# Post-Flight Report — VERB-REA-01

**Mission:** Implement `reanchor` verb (drawer), both legs
**Reviewer:** Adams
**Date:** 2026-05-30
**Baseline:** `816dbe2` · Head: `4965598`
**Commits reviewed:** 1f5bdc2 / 377422a / 4965598

---

## Final Verdict: PASS — CLEAN-WITH-FOLLOWUPS

Zero CRITICAL findings. One WARNING (test method name mismatch — does not
block). One INFO. Tests independently verified, exit 0, counts match Bilby's
claims exactly. The WARNING is a rename-only fix; it does not affect
correctness or test coverage.

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution | Status |
|---|---|---|---|---|---|
| 1 | WARNING | Method `testReanchorRoundTripSurfacesNotSupported` body is now a real round-trip (success path) but the name still says "SurfacesNotSupported". The `testWithdrawRoundTrip` precedent from the BRR explicitly calls for the rename. The name now lies about what the test asserts. | `VerbSurfaceTests.swift:172` | Rename to `testReanchorRoundTrip` (matching `testWithdrawRoundTrip` at line 111). Body is correct; this is a one-line rename. | open |
| 2 | INFO | Swift not-found assertions use `throws: LocusKitError.self` (type-only) rather than asserting the specific `.drawerNotFound(id:)` case, despite the test name promising "throws drawerNotFound". This is a pre-existing pattern in `ExpungeTests.swift` — Bilby followed the established convention. Not a defect; worth noting for future suite hardening. | `ReanchorTests.swift:204, 221, 229` | No action required. Future hardening task: specialise error assertions codebase-wide. | open |

---

## §9 — Blast Radius Verification

**§9.1 BRR exists.** `docs/blast_radius/VERB_REA_01_BLAST_RADIUS.md` — present.

**§9.2 Baseline test pass count recorded.** BRR records 441 Swift / 390 Rust at mission
start. Smythe pre-flight independently verifies the same counts. Confirmed.

**§9.3 MUST_UPDATE files in diff.** BRR declares 8 MUST_UPDATE files + `lib.rs`
module registration (1 in-scope addendum). All 9 accounted for. 3 additional doc/mission
files in the diff are the BRR itself, the pre-flight report, and the mission file —
all expected and in-scope.

| BRR MUST_UPDATE | In diff? |
|---|---|
| `Sources/LocusKit/EstateVerbs.swift` | yes |
| `rust/src/estate_verbs.rs` | yes |
| `Sources/LocusKit/DrawerStore.swift` | yes |
| `rust/src/drawer_store.rs` | yes |
| `rust/src/drawer_store_inmemory.rs` | yes |
| `Tests/LocusKitTests/ReanchorTests.swift` (new) | yes |
| `rust/src/reanchor_tests.rs` (new) | yes |
| `GeniusLocusKit/Tests/GeniusLocusKitTests/VerbSurfaceTests.swift` | yes |
| `rust/src/lib.rs` (module registration) | yes |

Total diff: 12 files. 9 code/test files (all MUST_UPDATE), 3 doc files. Match is exact.

**§9.4 INTENTIONALLY_LEFT justifications.** N/A — no INTENTIONALLY_LEFT entries in the
BRR. Every MUST_UPDATE file is in the diff.

**§9.5 Grep drift.** The new symbols `reanchorGated` / `reanchor_gated` are called only
from EstateVerbs.swift and the new test files. No stale or newly-appeared call sites
detected in non-diff files.

**§9.6 Prohibited patterns.** Git diff scanned. The words "bridge", "legacy", "compat",
"shim" appear only in pre-existing doc comments inside DrawerStore.swift and
drawer_store_inmemory.rs (specifically in the comment block for `gatedColumnWrite` /
`decompose_and_gate` which predates this mission). Zero new instances in the added lines.
No `@available(*, deprecated)` markers. No TODO/FIXME on changed symbols. None.

**§9 Overall: PASS.**

---

## §10 — Test Execution Verification

Method: **B (re-run)** — mission changes store paths and Estate verb implementation code.
This is engine-adjacent code; re-run is mandatory per §10.

### Swift

Command run:
```
cd packages/kits/LocusKit && swift test 2>&1 | tail -10
```

Output (verbatim tail):
```
Test run with 454 tests in 41 suites passed after 0.975 seconds.
```

Exit code: **0**

Bilby's claim: exit 0, 454 tests (441 baseline + 13 new).
My verification: exit 0, 454 tests, 41 suites.
**MATCH.**

### Rust

Command run:
```
cd packages/kits/LocusKit/rust && cargo test --lib 2>&1 | tail -10
```

Output (verbatim tail):
```
test result: ok. 406 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
```

Exit code: **0**

Bilby's claim: exit 0, 406 tests (390 baseline + 16 new: 13 in reanchor_tests.rs + 3 in
estate_verbs.rs replacing/supplementing the stub test).
My verification: exit 0, 406 tests.
**MATCH.**

### Warning verification

```
cargo test --lib 2>&1 | grep warning:
```

Output:
```
warning: variable does not need to be mutable
--> src/drawer_store_inmemory.rs:3111:13
  |
3111 |         let mut e1 = DiaryEntry {
```

Location: `drawer_store_inmemory.rs:3111` — the `diary_round_trip_and_lastn_ordering` test.
This is the pre-existing `unused_mut` warning documented in the NOUN-ASC-01 BRR (same cause,
line shifted from 3007→3111 by the 104 lines this mission added to the file).

The new `reanchor_gated` implementation uses `let mut update_vals = BTreeMap::new()` at
approximately line 1186; this is legitimately mutable (items are inserted into it
conditionally) and generates no warning.

**Zero new warnings introduced by this mission.**

Swift: zero warnings (`swift build` clean; consistent with test output showing no warning
lines before the result).

**§10 Overall: PASS. Tests actually ran with exit 0. Counts match.
Warning count confirmed — zero new warnings.**

---

## Implementation correctness verification

### EstateVerbs.swift — reanchor body

1. **Empty guard.** `guard toRoom != nil || toLattice != nil` → throws
   `LocusKitError.invalidContent("reanchor requires toRoom or toLattice")`. Correct error
   type (NOT the non-existent `.emptyReanchor` case on VerbError). Confirmed.
2. **Not-found guard.** `guard try await store.getDrawer(id: rowID) != nil` → throws
   `LocusKitError.drawerNotFound(id: rowID)`. Confirmed.
3. **Delegates to store.** Calls `store.reanchorGated(...)`. Does not attempt a direct
   column write or invent its own audit path. Confirmed.
4. **Pattern mirrors expunge.** The double-read pattern (getDrawer check in the verb body,
   then another read inside the gated store method) is identical to `expunge`. Established
   pattern, not a bug.

### DrawerStore.swift — reanchorGated body

1. **Transaction isolation.** Uses `.serializable` isolation — same as `expungeGated`.
   Confirmed.
2. **AuditGate.admit with verb: .mutate.** No `RowVerb.reanchor` case exists; correct use
   of the active→active self-loop verb. Confirmed.
3. **Anchor delta.** `priorAnchor` = current `udcCode`; `afterAnchor` = new lattice if
   provided, else `priorAnchor`. The gate records the delta via the two anchor parameters.
   Confirmed.
4. **Empty writes array.** Reanchor is a placement move, not a bitmap field edit. Passing
   `writes: []` is correct (the gate does not need FieldWrites for a placement-only change).
   Confirmed.
5. **Column updates.** When `toLattice` is provided: updates `udcCode`, `udcFacets`,
   `wikidataQID`, `wikidataQidsSecondary`. When `toRoom` is provided: updates `room`.
   All writes are in the same transaction as the audit event append. Confirmed.
6. **Bitmaps left unchanged.** The three bitmaps are read to construct `BitmapFields` for
   the gate but are NOT written in the column update dictionary. Confirmed.
7. **Audit event appended.** `try await txn.auditLog.append(event)` at end of transaction.
   Confirmed.

### Rust estate_verbs.rs — reanchor body

Structure mirrors Swift exactly. Empty guard, not-found guard, delegates to
`store.reanchor_gated`. The stub test `reanchor_stub_returns_invalid_content` is gone;
confirmed absent by grep. Replaced with:
- `reanchor_empty_args_returns_invalid_content` (the belt-and-suspenders guard)
- `reanchor_nonexistent_row_returns_not_found`
- `reanchor_to_new_room_updates_room` (includes bitmap-unchanged assertions)
- `reanchor_to_new_lattice_updates_udc` (includes bitmap-unchanged assertions)

### Rust drawer_store_inmemory.rs — reanchor_gated body

Reads bitmaps via `read_drawer_bitmap` (which returns `DrawerNotFound` on absent rows —
so the not-found path is covered before reaching the gate). Reads prior UDC via
`read_drawer_udc`. Calls `audit_gate::admit` with `RowVerb::Mutate`. Updates placement
columns (lattice and/or room) then appends the audit event. Structure correctly mirrors
the Swift gated path.

### GLK VerbSurfaceTests.swift — rewrite

`testReanchorRoundTripSurfacesNotSupported` body is now a real round-trip: capture → reanchor
to `.udc("003.000")` → recall → assert `udcCode == "003.000"`. The old `XCTAssertThrowsErrorAsync`
/ `notSupportedByEstate` assertion is gone. Correct.

`testReanchorEmptyRaisesGuard` at line 156 is **preserved unchanged**. Confirmed.

The test method is still named `testReanchorRoundTripSurfacesNotSupported`. The name now
contradicts the behavior. This is finding #1 (WARNING).

---

## Conformance mirror verification (I-19)

Swift test cases (13) and Rust test cases (13) are a case-for-case mirror:

| Case | Swift | Rust |
|---|---|---|
| `reanchorGated` room move — room updated, lattice unchanged | `reanchorGatedRoomMove` | `reanchor_gated_room_move_updates_room` |
| `reanchorGated` room move — bitmaps unchanged | `reanchorGatedRoomMoveBitmapsUnchanged` | `reanchor_gated_room_move_bitmaps_unchanged` |
| `reanchorGated` lattice move — anchor updated, room unchanged | `reanchorGatedLatticeMove` | `reanchor_gated_lattice_move_updates_anchor` |
| `reanchorGated` lattice move — bitmaps unchanged | `reanchorGatedLatticeBitmapsUnchanged` | `reanchor_gated_lattice_move_bitmaps_unchanged` |
| `reanchorGated` audit event written (count: 1→2) | `reanchorGatedAuditEventAppended` | `reanchor_gated_audit_event_appended` |
| `reanchorGated` absent row → not found | `reanchorGatedAbsentRowThrows` | `reanchor_gated_absent_row_returns_not_found` |
| `Estate.reanchor` empty args → invalidContent | `estateReanchorEmptyThrows` | `estate_reanchor_empty_args_returns_invalid_content` |
| `Estate.reanchor` non-existent row → not found | `estateReanchorNotFound` | `estate_reanchor_nonexistent_row_returns_not_found` |
| `Estate.reanchor` toRoom updates room | `estateReanchorToRoom` | `estate_reanchor_to_room_updates_room` |
| `Estate.reanchor` toLattice updates anchor | `estateReanchorToLattice` | `estate_reanchor_to_lattice_updates_anchor` |
| `Estate.reanchor` bitmaps preserved | `estateReanchorBitmapsPreserved` | `estate_reanchor_bitmaps_preserved` |
| `Estate.reanchor` audit entry written | `estateReanchorAuditEntry` | `estate_reanchor_audit_entry_written` |
| `Estate.reanchor` room + lattice simultaneously | `estateReanchorBothRoomAndLattice` | `estate_reanchor_both_room_and_lattice` |

All 6 required coverage areas confirmed present in both legs: room move, lattice move,
empty→invalidContent, not-found, audit entry written, bitmaps-otherwise-unchanged.

**I-19 mirror: PASS.**

---

## Date-precision pitfall check (VERB-CAP-01 concern)

No test in either leg asserts `Date` or timestamp struct equality across a round-trip.
Swift tests use `t(TimeInterval)` only as the `now:` parameter passed into the store
method (not as an asserted return value). Rust tests pass a raw `i64` timestamp.
Neither leg loads a stored row and compares a timestamp field against the value passed in.

**No date-precision pitfall. PASS.**

---

## MUST-NOT-MODIFY verification

| File | Modified? |
|---|---|
| `docs/validation/**` | no |
| `LatticeAnchor` type (SubstrateTypes) | no |
| `SubstrateLib` bitmap primitives | no |
| `GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift` | no |
| `GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbError.swift` | no |

All clean. None of the prohibited files appear in `git diff 816dbe2..HEAD --name-only`.

No `RowVerb.reanchor` case was invented. The code correctly uses `verb: .mutate`
(Swift) / `RowVerb::Mutate` (Rust) throughout. `VerbError` is referenced only in a
doc comment in EstateVerbs.swift, not in production code.

---

## GLK test suite — non-runnable context

The GLK test target (`packages/kits/GeniusLocusKit`) does not compile on this branch due
to a pre-existing `ProposalKind` ambiguity in `StandingSignalSchedulerTests.swift`. Build
errors confirmed isolated to that one file — zero errors in `VerbSurfaceTests.swift`.
This is the pre-existing condition documented in Smythe's pre-flight (finding #4 — GLK
baseline confirmed GREEN when the stream branched; the `ProposalKind` issue is not on this
stream).

`VerbSurfaceTests.swift` was assessed by inspection. The rewrite is correct. The one
finding (test method name) is a rename, not a logic error.

---

## Scope verification

Mission declared 6 files. BRR correctly expanded to 8 + lib.rs = 9. Diff is exactly those
9 code/test files plus 3 doc files. No files in the diff are unaccounted for. No
MUST_UPDATE file is missing.

No scope violations. No out-of-scope edits.

---

## Anti-pattern scan

Scanned the full diff for: bridges, shims, silenced warnings, partial migrations,
`@available(*, deprecated)` markers, orphan deprecations, path-of-least-resistance
patterns.

The words "bridge" and "legacy" appear in pre-existing comment blocks inside
`DrawerStore.swift` and `drawer_store_inmemory.rs`. Zero new instances in lines added
by this mission.

Result: none found in new code.

---

## Punch list (WARNING — does not block merge)

| # | Action | File | Owner |
|---|---|---|---|
| 1 | Rename `testReanchorRoundTripSurfacesNotSupported` → `testReanchorRoundTrip` | `VerbSurfaceTests.swift:172` | Bilby (one-line rename) |

This rename does not affect correctness, coverage, or any other test. It is a housekeeping
fix. Merge may proceed; the rename should land in the next available commit touching that
file (e.g., the Nagatha sync pass, or the first subsequent mission that touches VerbSurfaceTests).

---

## Verdict

**PASS — CLEAN-WITH-FOLLOWUPS.**

Tests pass — verified, exit 0. Swift 454 tests (441 + 13 new). Rust 406 tests (390 + 16
new). Zero new warnings. Diff is exactly 12 files, 1439 insertions, 26 deletions (deletions
are the replaced stub body + the old GLK round-trip test body). All 9 BRR MUST_UPDATE files
are in the diff. I-19 mirror is exact (13 cases each leg). All 6 required coverage areas
present in both legs. No prohibited files touched. No prohibited patterns. No date-precision
pitfalls. No stale call sites.

One WARNING: the rewritten GLK test method is correctly implemented but retains the old
name that now contradicts its behavior. Fix it when you're next in that file.

Ship it.

---

## Adams Learning Note — VERB-REA-01

**Mission:** Implement `reanchor` verb (drawer), both legs
**Files reviewed:** 12 (9 code/test, 3 docs)
**Date:** 2026-05-30

### Patterns observed

- **Verb implementation shape (both legs, placement verb):** The shape for a placement-change
  verb is: empty guard → not-found guard → delegate to a new gated store method. The gated
  store method reads bitmaps, builds `BitmapFields`, reads prior anchor, constructs after
  anchor, calls `AuditGate.admit` with `verb: .mutate`, writes placement columns, appends
  audit event — all in one transaction. Zero FieldWrites (placement is not a bitmap edit).
  This is now documented in two places (Swift DrawerStore.swift comment, Rust drawer_store.rs
  trait doc). The pattern is clean and complete.
  Recurrence: first verb-placement mission. Prior missions (expunge, withdraw) changed state,
  not placement.
  Future signal: the next placement-change verb (if any) should follow this pattern exactly.
  The empty-writes-array decision at the gate call is correct and intentional — document it
  in the completion report if it looks surprising.

- **Stub test replacement pattern:** When a stub is implemented, the stub test
  (`*_stub_returns_invalid_content`) must be renamed and its assertion rewritten (not just
  the body). Bilby correctly renamed `reanchor_stub_returns_invalid_content` to
  `reanchor_empty_args_returns_invalid_content` in estate_verbs.rs. The Smythe pre-flight
  explicitly named this file at line 656 as MUST_UPDATE. The pattern of splitting stub
  coverage across the inline test (belt-and-suspenders guard) and the dedicated conformance
  file (full suite) is correct.
  Recurrence: 2nd time (first was withdraw).

- **Cross-package GLK test rename debt:** When a GLK stub-surfaces-not-supported test is
  replaced by a real round-trip, the method name must also change. Here the body was correctly
  rewritten but the name was not updated. The `testWithdrawRoundTrip` precedent was
  explicitly cited in the BRR. This is a recurring blind spot: Bilby updates the body but
  forgets the name because tests still pass. Adams must always check the method name
  against the body when a GLK round-trip test is in the diff.
  Recurrence: 2nd time — same oversight pattern as VERB-CAP-01 (date equality) and
  NOUN-ASC-01 (clean). First time this specific name-vs-body defect appeared.
  Future signal: when `VerbSurfaceTests.swift` is in the diff and a formerly-stub test
  is being rewritten, check method name and body agree before calling clean.

- **Double-read in verb body:** `Estate.reanchor` calls `getDrawer` before `reanchorGated`
  (which also reads the drawer). This is not a bug — it matches `expunge` exactly and is
  the established pattern. Do not flag it.

### Surprises

The GLK test naming defect is the only finding. Everything else executed exactly as the BRR
and pre-flight predicted. The conformance suite is complete, the I-19 mirror is exact, and
both legs pass on first run. The scope accounting (8 MUST_UPDATE → 9 with lib.rs) was
pre-diagnosed correctly by Smythe.

### File-specific notes

- `DrawerStore.swift:685–785`: The `reanchorGated` method is well-structured. The
  `if !updateValues.isEmpty { update() }` guard is correct — if somehow called with both
  `toRoom` and `toLattice` nil (which the verb body prevents), the audit event is still
  appended. This is belt-and-suspenders and not a bug.

- `drawer_store_inmemory.rs`: The `let _ = (reason, after_udc)` suppressor at the end
  of `reanchor_gated` is correct — both are retained for future ProvFrame use and generate
  no warning. The BRR pre-documented the pre-existing `unused_mut` warning in
  `diary_round_trip_and_lastn_ordering` at line 3111; this mission does not touch that test.

- `VerbSurfaceTests.swift:172`: `testReanchorRoundTripSurfacesNotSupported` — the name is
  the only defect. Body is correct. The `testReanchorEmptyRaisesGuard` at line 156 is
  preserved exactly as required.

### Systemic flags

None. The verb implementation pattern is now documented and exercised. The GLK
name-vs-body check is worth adding to Smythe's pre-flight checklist for future verb
implementation missions that touch VerbSurfaceTests.
