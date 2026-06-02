# COMPLETION: SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001 — Converge the Verbs Oracle onto Canonical ForbiddenCombinations.check

**Status: COMPLETE**
Stream: fc · Branch: `stream/fc-forbidden-combo-converge`
Baseline: `4ef8a05` (= main) · Head: see final docs commit
Mission: `docs/missions/inflight/MISSION_SUBSTRATE_FORBIDDEN_COMBO_CONVERGE_001.md`
Date: 2026-06-01

---

## Summary

SubstrateLib now has exactly one forbidden-combination rule set. The Verbs
oracle `isLegalRowState` (`Verbs.swift:487`) delegates to the canonical
`ForbiddenCombinations.check` (`RowStateAutomaton.swift:244`), translating
`RowStateError.violatesInvariant(message)` →
`SubstrateError.forbiddenStateCombination(message)` with the message preserved.
A row mutated through the Verbs reference is now held to the same
I-22 + S-1 + S-2 + S-4 rule set as one mutated through LocusKit's API —
proven by a 40-tuple parity assertion driven through the public verbs.

The only behavior delta is the intended tightening: accepted rows through the
Verbs path now require trust ≥ canonical(3) (full S-1; the old oracle only
forbade trust = verbatim(0)) and sensitivity ≤ elevated(16) (S-4; the old
oracle had none). Signature, `private` access, `SubstrateError?` return, and
both callers (`capture` :121, `mutate` :229) are unchanged. Blast radius:
Tier 1 — 1 production symbol in 1 file + 1 test file.

## What Was Done

- **Part 0 — call-site audit** (recorded in the BRR): exactly three policy
  implementations confirmed (`ForbiddenCombinations.check` canonical;
  `isLegalRowState` the convergence target; LocusKit
  `ForbiddenCombinationValidator` intentional I-22-only defense-in-depth).
  `AuditGate.swift:305` recorded as a fourth **call site** of policy #1
  (consumer, unchanged). Rust mirrors classified: `row_state.rs:156`
  (site-1 mirror, surfaced by Smythe), `verbs.rs:552` (old-oracle mirror,
  follow-up), `forbidden_combination_validator.rs` (site-3 mirror). No unknown
  fourth implementation — STOP condition not tripped.
- **Part 1 — convergence** — `f25e198`
  (`fix(fc): converge Verbs oracle forbidden-combination check onto canonical ForbiddenCombinations.check`)
  - `isLegalRowState` body → `BitmapFields(adjective: UInt64(bitPattern:),
    operational: UInt64(bitPattern:), provenance: 0)` +
    `try ForbiddenCombinations.check` + error translation; doc-comment states
    the delegation and LocusKit-path faithfulness.
  - Inline literals deleted; grep for `"secret cannot be public"`,
    `"accepted cannot be verbatim"`, `"skip in this layer"` in `Verbs.swift`:
    zero matches.
  - Verify: `swift build` exit 0.
- **Part 2 — test reconciliation** — `b01087b`
  (`test(fc): reconcile Verbs oracle tests to canonical rule set; add parity assertion`)
  - `testMutateConfirmPendingToAccepted` updated: trust imported(2) →
    canonical(3) (the one test asserting old permissive behavior, per the
    BRR resolution table).
  - Added: S-1 boundary set (accepted + verbatim(0)/observed(1)/imported(2)
    rejected; + canonical(3) allowed), S-4 boundary set (accepted +
    restricted(32) rejected; + elevated(16) allowed), and
    `testOracleParityWithCanonicalCheck` — 40-tuple
    trust × sensitivity × exportability grid through `capture`
    (.active/.pending) and `mutate` (.accepted): verb-surface verdict ==
    `.check` verdict everywhere. (Oracle is `private`, so parity is driven
    through its two callers — which is also the stronger claim: the *public
    verb surface* is faithful to the canonical rule set.)
  - Verify: `swift test` exit 0, zero warnings.
- **Docs** — `0ce6dc9` (BRR + Smythe pre-flight + mission file),
  final commit (Adams post-flight + this report).

## Test Verification Log

### Baseline (mission start, commit 4ef8a05)
- Command: `cd packages/libs/SubstrateLib && swift test`
- Exit code: **0** · Pass count: **122 tests in 12 suites**
- Tail (verbatim): `Test run with 122 tests in 12 suites passed after 0.191 seconds.`

### Final (commit b01087b)
- Command: `cd packages/libs/SubstrateLib && swift test 2>&1 | tail -20`
- Exit code: **0** · Pass count: **129 tests in 12 suites** (= 122 baseline
  + 7 new; ≥ baseline, 1 assertion updated in place)
- Tail (verbatim): `Test run with 129 tests in 12 suites passed after 0.193 seconds.`
- `swift build --build-tests` warnings: **0**

Independently re-run and confirmed by Adams (§10).

### Expected-verdict table (reconciled against the live `.check` body)
| Case | Verdict | Rule |
|---|---|---|
| accepted + verbatim(0) | illegal (unchanged) | S-1 |
| accepted + observed(1) | **now illegal** (was legal) | S-1 |
| accepted + imported(2) | **now illegal** (was legal) | S-1 |
| accepted + canonical(3) | legal (boundary, inclusive) | S-1 |
| accepted + restricted(32) sens | **now illegal** (was legal) | S-4 |
| accepted + elevated(16) sens | legal (boundary, inclusive) | S-4 |
| secret(48) + public(32) | illegal (unchanged, all three sites) | I-22 |
| parity: 40-tuple grid, both verb legs | oracle == `.check` everywhere | authority |

The defused S-5 branch (tombstone check, off since 2026-05-27 pending F17)
moves **none** of these verdicts — the old oracle also skipped tombstone
enforcement, so no divergence to record beyond the BRR baseline-of-record.

## Smythe Pre-flight

Verdict: **GREEN — proceed.**
(`docs/blast_radius/FORBIDDEN_COMBO_CONVERGE_001_PREFLIGHT.md`)
- Independent Part 0 grep confirms exactly three policy implementations; the
  STOP condition is not tripped; the BRR caller list is accurate.
- Live `.check` body matches the BRR baseline-of-record exactly (I-22, S-1
  trust < 3, S-2 unreachable via the Verbs callers, S-4 sens > 16, S-5
  defused). No Part 2 verdict moved.
- Warning (honored): BRR first draft missed the **site-1 Rust mirror**
  `rust/src/row_state.rs:156` (`check_foreign_combinations`) — BRR corrected
  before implementation; classified as the site-1 mirror, unchanged.
- Warning (verified): the old message strings appear only in
  `Verbs.swift`/`verbs.rs`; **no test anywhere asserts on the message text**,
  so the canonical messages replacing them break nothing.
- Approach accepted as stated, including parity-through-public-verbs (oracle
  is `private`) and the `BitmapFields` construction mirroring
  `AuditGate.swift:295`.
- Environment clean: stream branch byte-identical to main on both target
  files; the sole not-parallel-safe stream (`tl`) has no live branch.

## Adams Post-flight

Verdict: **CLEAN-WITH-FOLLOWUPS.** Both BLOCKING checks PASS.
(`docs/blast_radius/FORBIDDEN_COMBO_CONVERGE_001_POSTFLIGHT.md`)
- **§9 Blast Radius Verification: PASS** — diff vs baseline = exactly 5 files
  (2 code + 3 docs), matching the BRR. Zero diff on any MUST-NOT-MODIFY file
  (`RowStateAutomaton.swift`, `ForbiddenCombinationValidator.swift`,
  `AuditGate.swift`, all `Package.swift`, `rust/src/verbs.rs`). Zero
  bridge/shim/compat/deprecation markers; zero inline forbidden-combination
  literals in `Verbs.swift`; INTENTIONALLY_LEFT justifications all specific
  and verifiable; BRR baseline-of-record matches source.
- **§10 Test Execution Verification: PASS** — independently re-ran: exit 0,
  129 tests in 12 suites, zero warnings — exact match with the claim.
- Implementation review: delegation correct (`UInt64(bitPattern:)` pattern as
  at `AuditGate.swift:295`; provenance=0 correct since `.check` doesn't read
  it); error translation faithful; catch-all judged "defensive insurance, not
  a silencer"; parity grid is machine-verified proof that survives future
  `.check` changes automatically.

### Adams findings resolution
| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | WARNING | Completion report + signal file not yet written | **Resolved by sequence** — this report and the `.done-fc` signal are written as the immediately following steps, per the execution order. |

No CRITICAL findings.

## Self-review (against the BRR MUST_UPDATE list)

- Diff matches the BRR file classification exactly: `Verbs.swift` (delegation,
  +22/−18), `VerbsTests.swift` (+164/−4), BRR, pre-flight, post-flight,
  mission file, this report. Nothing else.
- Success criteria walked: (1) one rule set in SubstrateLib, oracle delegates ✓
  (2) parity assertion proves Verbs faithful to the LocusKit path ✓ (3) the
  accepted-row tightening is the only behavior delta, intentional, covered ✓
  (4) LocusKit site 3 + `AuditGate.swift:305` recorded, untouched ✓ (5) Part 0
  confirms three policies; Rust mirrors surfaced and classified, not folded
  in ✓ (6) signature + both callers unchanged, Tier 1, no bridge/shim/
  deprecation/deferral marker ✓.
- No secrets, no silenced warnings, no `import XCTest`, no view code.

## Conditional lifecycle agents — evaluated

- **Kong — NOT spawned.** The design decision (which of three policies is
  canonical, why delegation not duplication, why site 3 stays) was made in the
  mission itself; this implementation introduces no new pattern, no governance
  gap, no cross-product surface. The Rust-leg follow-up is recorded, not
  designed here.
- **Perkins — NOT spawned.** No CloudKit/schema/BYOAI/Keychain/NL surface.
  The change is security-positive (tightens sensitivity/trust enforcement on
  accepted rows); no privacy-enforcement gap introduced.
- **Friedlander / Nert / Simms — N/A.** No UI, no user-facing behavior
  (library invariant enforcement; `user_facing: false`).
- **Scorandum — N/A.** Two field-extracts behind a function call on the
  mutation path; not perf-sensitive surface.
- **Nagatha docs-repo sync — deferred to post-merge** per standard flow.

## Discoveries

- **The Rust Verbs mirror now lags the converged Swift oracle.**
  `SubstrateLib/rust/src/verbs.rs:552` (`is_legal_row_state`) still carries
  the old policy (I-22 + accepted⇒trust≠verbatim). The Rust leg already has
  the canonical rule set at `rust/src/row_state.rs:156`
  (`check_foreign_combinations`, the site-1 mirror Smythe surfaced), so the
  follow-up is the same delegation move in Rust. Swift leads, Rust follows —
  separate mission.
- **S-2 is unreachable through the Verbs callers** — `mutate` derives the
  state from adjective bits 0–5 (so they agree by construction) and `capture`
  never passes withdrawn/rejected. The delegation carries S-2 along correctly
  but it can never fire on this path; no test can drive it from the public
  verb surface.
- **No consumer asserts on forbidden-combination message strings** (verified
  tree-wide by Smythe), so error-message convergence to the canonical
  "I-22:…"/"S-1:…" texts is free of downstream breakage.

## Outstanding (out of scope — not addressed)

- **Rust `verbs.rs` re-sync** to the converged policy (delegate to
  `check_foreign_combinations`), per the Discoveries entry above.
- **EE propagation** — CE and EE `SubstrateLib` were byte-identical at
  baseline; this change makes CE lead. Propagation is a separate task per the
  mission.
- **F17** — the defused S-5 tombstone check remains defused in the canonical
  body; nothing here changes that.
