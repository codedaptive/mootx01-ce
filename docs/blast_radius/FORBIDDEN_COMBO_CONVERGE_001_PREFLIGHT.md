# Smythe Pre-flight: SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001

**Agent:** Smythe · **Date:** 2026-06-01 · **Branch:** stream/fc-forbidden-combo-converge
**Baseline:** 4ef8a05 (= main)

---

## Status

**GREEN**

---

## Status details

- **Blast radius:** verified — exactly three policy implementations in the Swift tree, two Rust mirrors of known sites, no unknown fourth. Mission's three-policy premise holds.
- **Prior art:** none conflicting — no in-flight branch touches `Verbs.swift` or `RowStateAutomaton.swift`. `tl` stream (cited as not parallel-safe) does not exist as a live branch.
- **Environment:** clean — stream branch is byte-identical to main on both target files (`Verbs.swift`, `RowStateAutomaton.swift`). No staged changes.
- **Dependencies:** satisfied — `BitmapFields` (same module), `ForbiddenCombinations` (same module), `RowStateError` (`SubstrateTypes`, already imported) all accessible from `Verbs.swift` without import changes.

---

## Blockers

None.

---

## Findings and Warnings

### WARNING 1 — BRR omits the Rust mirror of site 1

The BRR's Part 0 Rust-mirror table lists two Rust mirrors (site 2: `verbs.rs:552`, site 3: `forbidden_combination_validator.rs:92`) but does not record the **Rust mirror of site 1**: `SubstrateLib/rust/src/row_state.rs` exports `check_forbidden_combinations` (line 156), the Rust port of `ForbiddenCombinations.check`. It implements the full I-22 + S-1 + S-2 + S-4 + S-5-defused rule set, is called by `row_state::validate` (line 139) and `audit_gate.rs:214`, and has its own conformance tests in `row_state.rs:306–369`.

This is **not a fourth policy and does not trip the Part 0 STOP condition.** It is the existing Rust mirror of the canonical site — same classification as the other two Rust mirrors, just not listed. Bilby does not need to touch it. Recording here so Adams does not flag it as a surprise.

The Part 0 grep target `"ForbiddenCombinations.check"` is a Swift symbol reference — it naturally misses the Rust function name `check_forbidden_combinations`. The BRR's "no unknown fourth implementation" verdict is correct; the omission is documentation only.

### WARNING 2 — Stale test line-number claim in BRR (cosmetic)

BRR resolution table says `testMutateConfirmPendingToAccepted` at `VerbsTests.swift:74`. Verified: `@Test func testMutateConfirmPendingToAccepted()` opens at line 74. Accurate.

### WARNING 3 — Error message strings change in Rust mirror (out-of-scope, expected)

`SubstrateLib/rust/src/verbs.rs:564` emits `"secret cannot be public"` and `:570` emits `"accepted cannot be verbatim"` — the old Verbs oracle message strings. These will diverge further from the Swift side after this mission (Swift messages will become the canonical I-22/S-1 messages). No test anywhere asserts on the string payload — all tests match on the case pattern (`ForbiddenStateCombination(_)`). No Swift test is broken by the message change. Rust-parity follow-up (already noted in BRR) will reconcile verbs.rs.

### INFO — No message-string observers outside production code

Grep confirmed: `"secret cannot be public"` and `"accepted cannot be verbatim"` appear only in production code (`Verbs.swift:500,504` and `verbs.rs:564,570`). No test, doc, or consumer outside those two files asserts on these strings. Message changes will not break anything except the Rust mirror's own internal comments, which are out of scope.

### INFO — All symbols needed for delegation are in scope

`Verbs.swift` already imports `SubstrateTypes` (which exports `RowStateError`). `BitmapFields` and `ForbiddenCombinations` are in the same `SubstrateLib` module. No `Package.swift` edits, no new imports required.

### INFO — S-5 defused branch confirmed

`RowStateAutomaton.swift:304–323` is the defused S-5 block. It contains no executable throw; `.check` performs no tombstone check today. The old oracle similarly skipped it (comment: "skip in this layer"). S-5 moves none of the Part 2 enumerated verdicts. BRR baseline-of-record is accurate.

### INFO — Parallel safety confirmed

`tl` stream (cited as the sole not-parallel-safe stream) has no live branch. Active streams `ar`, `dd`, `mt` have no commits touching `Verbs.swift` or `RowStateAutomaton.swift` against their branch bases.

---

## Bilby's stated approach

> Replace the hand-rolled body of `isLegalRowState` with: build `BitmapFields(adjective: UInt64(bitPattern: adjective), operational: UInt64(bitPattern: operational), provenance: 0)`, then `do { try ForbiddenCombinations.check(state: state, fields: fields); return nil } catch let e as RowStateError { if case .violatesInvariant(let m) = e { return .forbiddenStateCombination(m) } } catch { return .forbiddenStateCombination("unexpected error") }`. Keep `private` access and `SubstrateError?` return. Delete inline literals + comment block. Update doc-comment to state delegation. In `VerbsTests.swift`: update `testMutateConfirmPendingToAccepted` from trust=imported(2) to trust=canonical(3), add S-1 boundary cases (observed(1)/imported(2) now illegal, canonical(3) legal), add S-4 boundary (restricted(32) illegal, elevated(16) legal), add parity assertion driven through the public verbs.

**Assessment:** accepted. Approach matches the mission spec exactly. `UInt64(bitPattern:)` for the `Int64` → `UInt64` adjective/operational conversion is the correct pattern (same as `AuditGate.swift:295`). Provenance=0 is correct (`.check` does not inspect it). Defensive catch-all for non-`RowStateError` throws is appropriate since `ForbiddenCombinations.check` only throws `RowStateError` today, but the catch-all is cheap insurance. Parity assertion through the public Verbs API is the right call since `isLegalRowState` is `private`.

---

## Actions

1. Read `RowStateAutomaton.swift:244–323` and `Verbs.swift:487–507` before typing. (Terrain already read; confirm nothing has changed since this pre-flight.)
2. Part 1: Replace `isLegalRowState` body in `Verbs.swift`. Grep staged diff for `"secret cannot be public"`, `"accepted cannot be verbatim"`, `"skip in this layer"` — none may remain.
3. `swift build` in `packages/libs/SubstrateLib`. Must exit 0 before proceeding.
4. Part 2: Update `testMutateConfirmPendingToAccepted` (trust imported(2) → canonical(3)). Add S-1/S-4 boundary cases. Add parity assertion.
5. `swift test` in `packages/libs/SubstrateLib`. Must exit 0 and pass count ≥ 122.
6. Run pre-commit checklist. Commit Part 1, then commit Part 2.
7. Write signal to `/Users/bob/devlop/ddfactory/control/signals/.done-fc`.
8. Spawn Adams for post-flight.

---

## Decision needed

None. Terrain clear. Proceed.
