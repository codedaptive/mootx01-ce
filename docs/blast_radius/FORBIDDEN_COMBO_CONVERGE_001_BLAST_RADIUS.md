# Blast Radius Report — SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001

**Stream:** fc · **Branch:** stream/fc-forbidden-combo-converge
**Baseline:** 4ef8a05 (= main; CE trunk)
**Mission:** docs/missions/inflight/MISSION_SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001.md
**Date:** 2026-06-01
**Tier:** 1 (≤3 edits) — touches an existing primitive (RowState legality)

## Mission
Converge the Verbs oracle (`isLegalRowState`, `Verbs.swift`) onto the canonical
`ForbiddenCombinations.check` (`RowStateAutomaton.swift`) by delegation, so a row
mutated through the Verbs reference is held to the same I-22 + S-1 + S-2 + S-4
rule set as one mutated through LocusKit's API. Behavior-aligning bugfix: the
Verbs oracle's accepted-row legality *tightens* (gains full S-1 + S-4).

## Baseline test counts (at 4ef8a05, verified)
- SubstrateLib `swift test`: **122 tests in 12 suites**, exit 0.

## Mandatory Part 0 — call-site audit (grep run 2026-06-01 from worktree root)

### The three policy implementations (Swift, confirmed)
| # | Site | File | Rule set | Disposition |
|---|---|---|---|---|
| 1 | `ForbiddenCombinations.check` | `SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift:244` | I-22 + S-1 + S-2 + S-4 (S-5 defused, see Baseline-of-record) | **Canonical. READ ONLY.** |
| 2 | `isLegalRowState` | `SubstrateLib/Sources/SubstrateLib/Verbs.swift:487` | I-22 + "accepted ⇒ trust ≠ verbatim(0)" | **Convergence target. MODIFIED.** |
| 3 | `ForbiddenCombinationValidator` | `LocusKit/Sources/LocusKit/ForbiddenCombinationValidator.swift:52` | I-22 only, by documented design (hand-derived raws, defense-in-depth) | **Intentional. UNCHANGED.** |

### Callers (authoritative list)
| Caller | File:line | Calls | Disposition |
|---|---|---|---|
| `capture` | `Verbs.swift:121` | `isLegalRowState` | UNCHANGED (gets converged behavior) |
| `mutate` | `Verbs.swift:229` | `isLegalRowState` | UNCHANGED (gets converged behavior) |
| `RowStateAutomaton.validate` | `RowStateAutomaton.swift:195` | `ForbiddenCombinations.check` | UNCHANGED |
| **`AuditGate` basis gate** | **`AuditGate.swift:305`** | `ForbiddenCombinations.check` | **Fourth call site, NOT a fourth policy. Consumer of policy #1. UNCHANGED.** (Also calls `.check` indirectly via `RowStateAutomaton.validate` on the prior≠nil branch.) |
| Test callers | `RowStateAutomatonTests.swift:66–123` (6 calls), `LocusKit/Tests/ForbiddenCombinationTests.swift` | sites 1 / 3 | UNCHANGED (assert canonical behavior; not affected by the convergence) |

### Rust-leg mirrors found by the grep (recorded, classified — NOT new policies)
The mission's Part 0 grep over `packages/` also surfaces the Rust mirrors of the
known sites. None is a fourth *policy*; each is the existing port of a site
already in the table:

- `SubstrateLib/rust/src/row_state.rs:156` — `check_foreign_combinations`,
  mirror of **site 1** (full canonical rule set), called by the Rust `validate`
  and `audit_gate.rs:214`. Identified by Smythe pre-flight (corrects this BRR's
  first draft, which missed it). UNCHANGED, same disposition as site 1.
- `SubstrateLib/rust/src/verbs.rs:552` — `is_legal_row_state`, line-for-line
  mirror of **site 2's old body** (I-22 + accepted⇒trust≠0). After this mission
  the Rust Verbs leg lags the Swift leg (Swift leads, Rust follows per CE
  convention). **Out of scope here** — the mission's Files-You-Will-Modify list
  is exhaustive (`Verbs.swift` + SubstrateLib Swift tests) and Tier 1 caps the
  edit count. Recorded as a follow-up: re-sync `verbs.rs` to the converged
  policy in a Rust-parity pass, delegating to the `row_state.rs`
  `check_foreign_combinations` mirror exactly as the Swift side delegates to
  `.check`.
- `LocusKit/rust/src/forbidden_combination_validator.rs:92` — mirror of site 3
  (intentional I-22-only). UNCHANGED, same rationale as site 3.

### Non-policy matches from the raw-int grep (all cleared)
- `NeuronKit` MaintenanceDaemon/Seams/Decision + `GeniusLocusKit` maintenance
  signals — I-3 *scan* over already-written drawers (enum-based, maintenance
  layer), a consumer of the invariant concept, not a row-write legality policy.
- `PersistenceKit/GeneratedColumn.swift` — doc-comment reference to the 6-bit
  field extract for a generated SQL column, not a rule copy.
- `SubstrateTypes` SimHash tests, `LocusKit/rust/tests/*_conformance.rs` —
  bitmap field-extract arithmetic in tests, unrelated to forbidden combos.

**Part 0 verdict: exactly three policy implementations in the Swift tree (plus
their two Rust mirrors of sites 2 and 3). No unknown fourth implementation. The
STOP condition is not tripped: the plan's three-policy premise holds.** The
`verbs.rs` mirror is surfaced above (not folded in) per the mission's
do-not-fold-in instruction.

## Baseline-of-record — what `.check` ACTUALLY throws on today
Read from `RowStateAutomaton.swift:244–323` (the live body, including the
defused branch):

1. **I-22** (state-independent): `sensitivity == 48 && exportability == 32` →
   throws `violatesInvariant("I-22: secret row cannot be exportable (sensitivity=secret + exportability=public)")`.
2. **S-1** (`state == .accepted`): `trust < 3` (bits 18–23) →
   throws `violatesInvariant("S-1: accepted row must have trust ≥ canonical")`. Boundary **inclusive** at canonical(3).
3. **S-2** (`state == .withdrawn || .rejected`): adjective bits 0–5 must encode
   the state's own rawValue (withdrawn=18, rejected=32) → throws
   `violatesInvariant("S-2: …")`. *Unreachable through the Verbs callers*
   (`mutate` derives state FROM bits 0–5, so they always agree; `capture` never
   passes withdrawn/rejected), so no Verbs-visible behavior change from S-2.
4. **S-4** (`state == .accepted`): `sensitivity > 16` (bits 6–11) →
   throws `violatesInvariant("S-4: accepted row must have sensitivity ≤ elevated")`. Boundary **inclusive** at elevated(16).
5. **S-3** — enforced by the transition table, no field check in `.check`.
6. **S-5 — DEFUSED branch (2026-05-27)**: the tombstoned-row field check is
   commented out pending F17; `.check` performs **no tombstone check today**.
   The old oracle also skipped it ("(1) tombstoned… skip in this layer"), so
   the defused branch moves **none** of the Part 2 enumerated verdicts.

Reconciliation: every Part 2 expected verdict in the mission matches this live
body. No divergence between documented and live behavior for the enumerated
cases.

## Symbols being changed
- `isLegalRowState(state:adjective:operational:)` (`Verbs.swift:487`) —
  **semantic**: hand-rolled body replaced by delegation to
  `ForbiddenCombinations.check` + error translation
  (`RowStateError.violatesInvariant(msg)` → `SubstrateError.forbiddenStateCombination(msg)`,
  message preserved). Signature, `private` access, and `SubstrateError?` return
  preserved. Both callers untouched.

## Files — classification
| File | Class | Note |
|---|---|---|
| `packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift` | MUST_UPDATE | `isLegalRowState` body → delegation; doc-comment updated; inline literals deleted |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/VerbsTests.swift` | MUST_UPDATE | the exact test file (named per mission): 1 stale assertion updated (below), S-1/S-4 boundary cases + parity assertion added |
| `docs/blast_radius/FORBIDDEN_COMBO_CONVERGE_001_BLAST_RADIUS.md` | NEW | this report |
| `docs/blast_radius/FORBIDDEN_COMBO_CONVERGE_001_PREFLIGHT.md` | NEW | Smythe pre-flight |
| `docs/status/STREAM_fc_FORBIDDEN_COMBO_CONVERGE_001_COMPLETION.md` | NEW | completion report |
| `docs/missions/inflight/MISSION_SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001.md` | NEW (commit of dispatched file) | mission rides the stream branch |

## Tests asserting the old permissive accepted-row behavior (resolution table)
| Test | File:line | Old assertion | Resolution |
|---|---|---|---|
| `testMutateConfirmPendingToAccepted` | `VerbsTests.swift:74` | accepted + **imported(2)** succeeds (comment: "trust=imported(2) so accepted+trust is legal") | Update to **canonical(3)** — accepted+imported is illegal under S-1. The only existing test asserting a combination the canonical rule set rejects. |

All other existing tests cleared: `testForbiddenSecretPublicComboRejected`
(I-22, verdict unchanged), `testWithdrawActiveToWithdrawn` (re-confirm to
**active**, S-1/S-4 don't apply), remaining tests use trust-0/sensitivity-0
bitmaps in non-accepted states. `RowStateAutomatonTests` assert site 1 directly
and are unaffected.

## INTENTIONALLY_LEFT (verified, with justification)
- `RowStateAutomaton.swift` — canonical rule set; converge toward it. (Mission MUST-NOT-MODIFY.)
- `LocusKit/ForbiddenCombinationValidator.swift` — documented I-22-only defense-in-depth. (Mission MUST-NOT-MODIFY.)
- `AuditGate.swift` — fourth caller, consumer of policy #1. (Mission MUST-NOT-MODIFY.)
- Any `Package.swift`, `docs/concepts/`, anything outside SubstrateLib. (Mission MUST-NOT-MODIFY.)
- `SubstrateLib/rust/src/verbs.rs` — Rust mirror of the old oracle; recorded
  follow-up (Swift leads, Rust follows), needs the canonical rule set ported to
  the Rust leg first. Deliberately NOT a same-symbol deferral marker in source —
  the divergence is recorded here and in the completion report.
- EE tree — out of scope per mission (CE is the work surface).

## RESCOPE_REQUIRED
None. Blast radius within Tier 1: 1 production symbol in 1 file + 1 test file.
