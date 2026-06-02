# Mission SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001 — Converge the Verbs Oracle onto Canonical ForbiddenCombinations.check

## Priority: P1
## Stream: fc
## Branch from: main
## Depends on: None
## Parallel safe with: any mission that does not touch `SubstrateLib/Verbs.swift`. NOT parallel-safe with `tl` (which cites the same SubstrateLib region).

---

## Context

**Tree.** This mission targets **mootx01-ce**, base branch **main**. CE is the work surface; it has no `develop`, so `main` is the trunk to branch from. CE and EE `SubstrateLib` are byte-identical today, but EE is not the target — propagating this change to EE, if desired, is a separate task and is out of scope here.

**Three forbidden-combination policies exist in the tree, and they have drifted** (all confirmed against CE source):

1. **`ForbiddenCombinations.check`** — `SubstrateLib/RowStateAutomaton.swift` (`public enum ForbiddenCombinations`, `static func check`). The **richest** policy: I-22 (secret ⇒ ¬public), S-1 (accepted ⇒ trust ≥ canonical), S-2 (withdrawn/rejected state-encoding defense), S-4 (accepted ⇒ sensitivity ≤ elevated). Reached by LocusKit's mutation API via `RowStateAutomaton.validate`, and by the audit basis gate (see fourth call site below). Uses raw-int extraction (`(adjective >> 6) & 0x3F`).
2. **`isLegalRowState`** — `SubstrateLib/Verbs.swift` (`private func`, ~line 487), called by `capture` (~121) and `mutate` (~229) in that file. Enforces I-22 + "accepted ⇒ trust ≠ verbatim(0)". **Weaker than AND different from S-1**: it permits accepted+observed(1) and accepted+imported(2), which `ForbiddenCombinations.check` rejects; and it has no S-4 (permits accepted+restricted). A distinct, older policy — not a typo of the canonical one. **This is the convergence target.**
3. **`ForbiddenCombinationValidator`** — `LocusKit/ForbiddenCombinationValidator.swift`. I-22 **only**, by deliberate design (its doc-comment hand-derives the raws so enum-case changes cannot silently shift the check). **Not drift** — a documented defense-in-depth I-22 check. Recorded, left unchanged.

**A fourth call site, not a fourth policy.** `AuditGate.swift:305` invokes `try ForbiddenCombinations.check(state:fields:)`. It is a **consumer** of policy #1, not a separate rule set, so it does not trip the Part 0 STOP condition. It is recorded in the BRR so post-flight does not treat it as a surprise — and it is corroborating evidence that `.check` is the canonical policy (the content-addressed audit gate already delegates to it).

**The drift that matters:** a row mutated through LocusKit's API (→ `.check`) is held to S-1/S-4; the same logical operation through the Verbs reference (→ `isLegalRowState`) is not. This mission makes the Verbs oracle enforce the same rule set as `.check`. Both live in SubstrateLib and `.check` is importable from `Verbs.swift`, so convergence is a delegation, not a cross-layer import. **SubstrateLib cannot import LocusKit** (verified: `LocusKit/Package.swift` depends on SubstrateLib, not the reverse), which is why site 3 is left as-is and convergence happens entirely within SubstrateLib.

**This is a behavior-aligning bugfix, called out so review does not read it as a regression:** the Verbs oracle's accepted-row legality *tightens* to match `.check` (gains S-1's full strength and S-4). That tightening is the point.

This mission **touches existing primitives** (RowState legality / forbidden-combination invariants); **blast radius applies. Tier 1 (≤3 edits).**

## Read First
- `SubstrateLib/RowStateAutomaton.swift` — `ForbiddenCombinations.check`. **Read lines 244–322 in full, including the branch marked "Defused 2026-05-27 during S-1 plumbing."** The live body is the contract; the prose summary "I-22 + S-1 + S-2 + S-4" is documentation, not a substitute for reading what `.check` actually throws on today. (READ ONLY here.)
- `SubstrateLib/Verbs.swift` — `isLegalRowState` and its two callers `capture`, `mutate`. The site being converged.
- `LocusKit/ForbiddenCombinationValidator.swift` — site 3 (READ ONLY; recorded, not changed).

## Mandatory Part 0 — Call-site audit (against the CE tree; do this first)
From the CE repo/worktree root, grep for every forbidden-combination implementation and caller before editing:
```
grep -rn "isLegalRowState"              packages/
grep -rn "ForbiddenCombinations.check"  packages/
grep -rn "ForbiddenCombinationValidator" packages/
grep -rn "secret.*public\|sensitivity == 48\|>> 6) & 0x3F" packages/   # raw-int copies
```
Record the authoritative list in the BRR, **including `AuditGate.swift:305` as a fourth call site of `ForbiddenCombinations.check`** (consumer, not modified). If a **fourth forbidden-combination IMPLEMENTATION** or a raw-int copy of the *rule* exists beyond the three policy sites, STOP and surface it — do not fold it in. The plan is built on exactly three policies; a fourth implementation changes scope.

## Blast Radius Scope

**Symbols being changed:**
- `isLegalRowState(state:adjective:operational:)` (`Verbs.swift`) — **semantic**: rule set replaced by delegation to `ForbiddenCombinations.check`. Signature and `SubstrateError?` return preserved; the two callers (`capture`, `mutate`) are untouched.

**Read, not changed:** `ForbiddenCombinations.check` (already canonical); `ForbiddenCombinationValidator` (LocusKit site 3, intentionally I-22-only); `AuditGate.swift:305` (fourth caller).

**Expected blast radius (Skippy's estimate):**
- Production code: 1 symbol, 1 file (`Verbs.swift`).
- Tests: SubstrateLib tests asserting the old permissive accepted-row behavior — enumerate each in the BRR, update in this mission, no deferral.
- Docs: none.

**Baseline-of-record (BLOCKING for the BRR):** the BRR baseline MUST record what `.check` **actually** throws on today — read from `RowStateAutomaton.swift:244–322`, including the defused branch — not the documented description. The Part 2 enumerated cases are reconciled against that live behavior; the parity assertion is the safety net, not a substitute for reading the body.

## Files You Will Modify
- `packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift` — replace `isLegalRowState` body with delegation + error translation.
- `packages/libs/SubstrateLib/Tests/SubstrateLibTests/…` — update/add tests for the converged behavior (exact file named in the BRR).

## Files You MUST NOT Modify
- `RowStateAutomaton.swift` (canonical rule set — converge toward it, not it toward anything).
- `LocusKit/ForbiddenCombinationValidator.swift` (site 3 is intentional; changing it is a separate decision).
- `AuditGate.swift` (fourth caller — recorded, unchanged).
- Any `Package.swift`. `docs/concepts/`. Anything outside SubstrateLib.

## Implementation Parts

### Part 1 — Converge the Verbs oracle onto the canonical rule set
In `Verbs.swift`, replace the hand-rolled body of `isLegalRowState` with a call to `ForbiddenCombinations.check`:
- Build `BitmapFields(adjective: UInt64(bitPattern: adjective), operational: UInt64(bitPattern: operational), provenance: 0)` (`.check` reads only the adjective field; provenance unused, 0 is faithful).
- `do { try ForbiddenCombinations.check(state: state, fields: fields); return nil } catch let e as RowStateError { … }`.
- Translate `RowStateError.violatesInvariant(message)` → `SubstrateError.forbiddenStateCombination(message)`, preserving message text.
- Delete the inline `sensitivity == 48 && exportability == 32` and `state == .accepted && trust == 0` checks and the "(1) tombstoned… skip in this layer" comment block. Grep the staged diff for `"secret cannot be public"`, `"accepted cannot be verbatim"`, `"skip in this layer"` — none may remain.
- Update the doc-comment to state the oracle now delegates to `ForbiddenCombinations.check` (the single SubstrateLib rule set) and is faithful to the LocusKit mutation path.

**Commit:** `fix(fc): converge Verbs oracle forbidden-combination check onto canonical ForbiddenCombinations.check`
→ verify: `cd packages/libs/SubstrateLib && swift build`; grep confirms no inline forbidden-combination literals remain in `Verbs.swift`; run the pre-commit checklist.

### Part 2 — Reconcile tests to the canonical rule set
Update SubstrateLib tests and add the cases the drift exposed. **Each expected verdict below is the documented S-1/S-4 behavior; confirm each against the live `.check` body before asserting** (the defused branch may move one of these — if it does, the test follows the source, and the BRR records the divergence):
- accepted + verbatim(0) → illegal (unchanged; both policies forbade it).
- accepted + observed(1) → now illegal (S-1; was legal via the old oracle).
- accepted + imported(2) → now illegal (S-1).
- accepted + canonical(3) → legal (S-1 boundary, inclusive).
- accepted + restricted(32) sensitivity → now illegal (S-4); accepted + elevated(16) → legal (S-4 boundary).
- secret(48) + public(32) → illegal (I-22, unchanged across all three sites).
- **Parity assertion:** over a representative (state, adjective) set, `isLegalRowState(…) == nil` iff `ForbiddenCombinations.check(…)` does not throw. This is the authority; the enumerated cases above are the human-readable cross-check.

Every test asserting an accepted combination legal under the old oracle is updated and listed in the BRR's resolution table.

**Commit:** `test(fc): reconcile Verbs oracle tests to canonical rule set; add parity assertion`
→ verify: `cd packages/libs/SubstrateLib && swift test 2>&1 | tail -20` exits 0.

## Test Requirements
The accepted-row cases with both S-1 and S-4 boundaries (reconciled to the live `.check` body); the parity assertion; no test asserts an accepted combination legal that `ForbiddenCombinations.check` rejects.

## Test Verification Log

### Baseline (mission start)
- Pass count at mission start: NNN (must exit 0; else STOP, write `.stuck`).

### Final
- Command: `cd packages/libs/SubstrateLib && swift test 2>&1 | tail -20`
- Exit code: 0
- Pass count: NNN (≥ baseline, accounting for updated assertions)
- Tail output (verbatim): …

## Verification
`swift build` + `swift test` green. Grep: zero inline forbidden-combination literals in `Verbs.swift`; SubstrateLib now has exactly one rule set (`ForbiddenCombinations.check`) with the oracle delegating to it. Run self-review against the BRR's MUST_UPDATE list. Spawn Adams for post-flight: no bridge/shim/parallel policy in SubstrateLib; LocusKit site 3 and the `AuditGate` caller untouched; the two `isLegalRowState` callers unchanged; behavior change confined to accepted-row legality in the Verbs reference, intentional and covered.

## Success Criteria
1. Within SubstrateLib, `isLegalRowState` delegates to `ForbiddenCombinations.check`; no second rule set survives in that package.
2. The Verbs oracle is faithful to the LocusKit mutation path — proven by the parity assertion.
3. The accepted-row tightening (gains full S-1 + S-4, reconciled to the live body) is the only behavior delta, intentional, covered.
4. LocusKit site 3 is recorded as the intentional I-22-only defense and left unchanged; `AuditGate.swift:305` is recorded as a fourth caller and left unchanged.
5. Part 0 confirms exactly three policy sites; no fourth implementation or raw-int copy exists (or it was surfaced, not folded in).
6. Signature and both callers unchanged; blast radius within Tier 1; no bridge, shim, deprecation, or same-symbol deferral marker.

## Signal File
Write to: `/Users/bob/devlop/ddfactory/control/signals/.done-fc`
