# Post-Flight Review — SML-TEST-01

**Reviewer:** Adams
**Date:** 2026-05-31
**Final Status:** PASS-WITH-FINDINGS

---

## Blocking Check Results

| Check | Claim | Verification | Result |
|---|---|---|---|
| §9 Blast Radius | 24 test files + 3 docs; no Sources/ or rust/ or validation/ touched; Package.swift untouched | `git diff --name-only b42db96..HEAD` = 27 files; `git diff b42db96..HEAD -- Sources/** rust/** docs/validation/**` = empty; `git diff b42db96..HEAD -- Package.swift` = empty | **PASS** |
| §10 Swift test | exit 0, 150 tests in 24 suites | Re-ran: `Test run with 150 tests in 24 suites passed after 0.021 seconds.` EXIT: 0 | **PASS** |
| §10 Rust test | exit 0, 70 passed | Re-ran: `test result: ok. 70 passed; 0 failed; 0 ignored` EXIT: 0 | **PASS** |

---

## First Pass Findings

| # | Severity | Finding | File/Location | Resolution | Status |
|---|---|---|---|---|---|
| 1 | WARNING | Signal file not written. `ls /Users/bob/devlop/ddfactory/control/signals/.done-smltest` returns no such file. Mission spec explicitly requires this file. Downstream orchestrator depends on it. | Mission §Signal File | Bilby writes the signal file: `touch /Users/bob/devlop/ddfactory/control/signals/.done-smltest` | open |

---

## Blast Radius Verification

**Files claimed in diff:** 24 test files + 3 doc files = 27 total
**Files actually in diff:** 27 (exact match)

**Production sources in diff:** None. `Sources/**`, `rust/**`, `docs/validation/**` — zero diffs confirmed by git.

**Package.swift modified:** No. Confirmed by empty diff. The conditional-additive row resolved to "present" (swift-testing toolchain-bundled); no change required.

**MUST_UPDATE files missing from diff:** None. All 23 peer suite creates, SubstrateMLTests.swift rewrite, FloatSimHashTests.swift conversion — all present.

**Zero `import XCTest` in test sources:** Confirmed. Grep returned only `.build/arm64-apple-macosx/debug/SubstrateMLPackageTests.derived/runner.swift` (toolchain-generated artifact, not a source file). No match in `Tests/**`.

**Prohibited patterns:** None. The word "bridge" appears in a test string literal ("two cliques with a weak bridge") — domain vocabulary, not a code pattern. The word "compat" appears as a parameter name `compatibleSeedScope` — it is the production API's parameter name, not a shim. No `@available(*, deprecated)`, no TODO/FIXME, no silenced warnings.

---

## Test Execution Verification

**Method:** B (re-run) — mission changes test infrastructure, prior baseline was XCTest (0 swift-testing tests), so a spot-check of logs would be insufficient.

**Swift leg:**
```
Test run with 150 tests in 24 suites passed after 0.021 seconds.
EXIT: 0
```
Matches claim: 150 tests, 24 suites, exit 0.

**Rust leg:**
```
test result: ok. 70 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
EXIT: 0
```
Matches claim: 70 passed, exit 0. Rust was not touched; this confirms the baseline was preserved throughout.

---

## Implementation Review

### Coverage completeness

23 `Sources/SubstrateML/` types. 24 test suites (23 peer suites + the package smoke). One-to-one mapping confirmed by filesystem listing.

### Parity spot-checks

**CompositeDistance** (5 Rust tests → 5 Swift tests)
Case-for-case mirror confirmed. Same tolerances (1e-12), same inputs (lattice=0.4, hamming=128 for cross-perimeter, hamming=64 for weight skew and linearity), same expected values (0.45, 0.20, 0.385, linearity halving). The `compatibleSeedScope: false` branch is tested. Clean.

**LatticeDistance** (11 Rust tests → 11 Swift tests)
Full mirror confirmed. `MockGraph` adjacency provider reproduced in Swift (class, not struct — appropriate for the mutation pattern). UDC identical-zero, shared-prefix (0.5), no-common-prefix (5/3 — d>1 permitted), empty-strings, Wikidata identical-zero, null-QID-maximal, 1-hop `1 - exp(-1/3)`, 3-hop `1 - exp(-1)`, beyond-depth-returns-1.0, combined-reflexive, combined-weighted — all 11 present with matching expected values. Tolerances match (1e-9 throughout). Clean.

**MatrixDecay** (7 Rust tests → 7 Swift tests)
Case-for-case mirror confirmed. Same half-life (100s), same timestamps (0→100, 0→200, 50→50, 100→50), same values (1.0→0.5, 1.0→0.25, decay-and-add round-trip to 1.0, decayFactor=1.0 at zero elapsed). The no-backward assertion checks both the value AND the lastDecayTimeSeconds field, matching the Rust `assert_eq!(m.last_decay_time_seconds, 100)`. Clean.

**PartialStateRecall** (7 Rust tests → 7 Swift tests)
Mirror confirmed. `identical_scores_zero`, `complement_scores_zero`, `ideal_partial_match` (match_d=0, differ_d=128 → score=1.0), `empty_match_blocks_zero`, `empty_differ_blocks_zero`, `top_k_orders_descending`, `top_k_respects_k` — all 7 present. The Swift `rid()` helper maps `RowId(n)` to fixed UUIDs (last byte = n). The `matchBlocks` and `differBlocks` use `Array` literals passed as sequences — correct. Tolerance 1e-12. Clean.

**FFT** (6 Rust tests → 5 Swift tests + 1 documented divergence)
`dc_input`, `pure_tone`, `rhythm_zero`, `rhythm_alternating`, `rhythm_long_period` — all 5 mirrored case-for-case, same inputs, same expected values, same tolerances (1e-12 for DC, 1e-9 for rhythm). The 6th Rust test (`non_power_of_two_panics`) uses `std::panic::catch_unwind` — Swift `precondition` traps the process and is not catchable by `#expect(throws:)`. The divergence is legitimate: the Swift language does not provide a test-catchable equivalent. The positive power-of-two tests implicitly validate that the precondition fires only on invalid input. Clean.

**FloatSimHash** (5 Rust tests → 5 Swift tests)
Converted from XCTest. Both previously-unseeded similarity tests (`similarVectorsClose`, `orthogonalVectorsFarApart`) now use fixed deterministic input vectors matching the Rust `float_simhash.rs` pattern. The `0xDEAD_BEEF` seed used in `deterministic` and the smoke test matches the Rust canonical. `emptyVectorReturnsZero` present. Clean.

### Derived suites (Rust-zero-test types)

**AuditLogFold** — 8 tests derived from documented properties (§5.3/§8.15): no-events nil, other-rows-ignored, single-event projection, last-writer-wins, determinism-under-permutation, as-of-truncation, tombstone-sticky (I-22), projectAll-groups-by-row. Not trivial. Tests actual semantic properties of the fold operation including edge cases (nil row, arrival-order independence, HLC ordering). Clean.

**InformationTheory** — 13 tests derived from closed-form mathematical properties: entropy of certain outcome = 0, fair coin = 1 bit, uniform-4 = 2 bits, zeros-skipped, KL-self-zero, KL-non-negative, KL-asymmetric, cross-entropy-equals-entropy-on-self, JS-self-zero, JS-symmetric-and-bounded, JS-orthogonal=1, MI-independent-zero, MI-perfect-correlation=1, NMI bounds. These are canonical information-theory axioms, not tautological assertions. Clean.

**ActionOutcomeMatrix** — 8 tests covering: empty matrix, observation accumulation, distinct cells, Wilson-is-conservative, empty-cell-zero, Wilson-tightens-with-evidence, topActions-prefers-evidence (verifying that a 1/1 cell loses to an 18/20 cell under Wilson lower bound), topActions-limits-and-filters. The Wilson bound test is behavioral, not trivial. Clean.

### Documented divergences assessed

1. **FFT `non_power_of_two_panics`:** Legitimate. Swift `precondition` is a process-killing trap. No equivalent to `std::panic::catch_unwind` exists in swift-testing. The precondition is enforced by the implementation and exercised indirectly by all positive-path tests. Not a missing assertion.

2. **Pairing `diversified_seeds_differ_per_block`:** Legitimate. `HyperplaneFamily.diversifiedSeed` is a SubstrateTypes internal. The PairingHandshake suite verifies the behavioral consequence (distinct block hashes ⇒ distinct seeds) via the `shared_family_blocks_are_distinct` test, which directly matches the Rust `shared_family_blocks_are_distinct` behavior. The internal function under test belongs to the SubstrateTypes leg.

### Overall assessment

The suites are not trivial. Derived suites (Rust-zero-test types) assert documented behavioral invariants, edge cases, and mathematical properties — not just "the function returns a value." Tolerances are mirrored from Rust throughout (1e-12 for exact arithmetic types, 1e-9 for BFS-distance formulas, 1e-5 for float32 information theory). Seeds are deterministic and sourced from the Rust mirrors.

---

## Learning Note — SML-TEST-01

**Mission:** SubstrateML swift-testing library test leg
**Files reviewed:** 24 swift-testing suites + SubstrateMLTests.swift + FloatSimHashTests.swift + 3 doc files
**Date:** 2026-05-31

### Patterns observed

- **Signal-file omission:** `.done-smltest` not written despite explicit Signal File section in the mission. Recurrence: observed in SML-TEST-01. Future signal: Check signal file existence at end of every post-flight. The orchestrator depends on these for dependency gating.
- **XCTest in .build/ — non-violation:** `grep -r "import XCTest"` on a package that completed an XCTest→swift-testing conversion will always match the toolchain's derived runner at `.build/**`. This is not a violation. The check passes when only `.build/**` paths are returned.

### Surprises

- The `non_power_of_two_panics` divergence is a legitimate untestable-under-swift-testing case — a real language-level constraint, not an omission. First time seeing this pattern explicitly documented in a BRR. Good practice.
- 150 tests across 24 suites is a large, clean first run — zero failures, zero warnings. The suite is genuinely comprehensive.

### File-specific notes

- `LatticeDistanceTests.swift`: MockGraph implemented as a `final class` rather than struct — correct, since it has a mutation method (`edge`) used in a builder pattern. This is not a bug.
- `PartialStateRecallTests.swift`: `private let tol = 1e-12` is declared at the bottom of the struct body — unusual ordering but valid Swift.

### Systemic flags

None. TEST-ONLY mission. No architectural concerns surfaced.
