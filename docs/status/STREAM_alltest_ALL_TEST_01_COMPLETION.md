# COMPLETION: ALL-TEST-01 — AriaLexiconLib library test leg (swift-testing, both legs)

**Status: COMPLETE**
Stream: alltest · Branch: `stream/al-arialexiconlib-test-leg`
Baseline: `b42db96` · Head: `173ed1e`
Mission: `docs/missions/inflight/MISSION_ALL_TEST_01.md`
Date: 2026-05-31

---

## Summary

AriaLexiconLib's Swift test leg now has per-source-type swift-testing peer
suites mirroring `Sources/`, with every one of the 5 types covered and full
parity to the 9 Rust `#[test]` behaviors. Both legs are green with zero
warnings. **No production source was modified — this is a test-only mission.**

**Premise correction (load-bearing).** The mission's central claim — that
`LexiconTests.swift` uses `import XCTest` and registers "0 tests in 0 suites" —
was **false against the actual tree**. The file already used `import Testing`,
declared `@Suite("AriaLexiconLibTests")`, held 9 `@Test` methods, and registered
9 tests at baseline. The XCTest→swift-testing conversion described in Part 1 was
**already done** (it shipped in the `v0.8` import, commit `719cb08`); there is no
`import XCTest` anywhere under `Tests/`. Smythe surfaced this at pre-flight
(YELLOW, no RESCOPE — scope is *narrower* than claimed). The real remaining work
was the 4 per-type peer suites, which this stream delivered.

## What Was Done

- **BRR + Smythe pre-flight** — `bc48449`
  (`docs(alltest): ALL-TEST-01 blast radius report + Smythe pre-flight`)
  - Blast Radius Report (`docs/blast_radius/ALL_TEST_01_BLAST_RADIUS.md`) and
    Smythe's pre-flight (`docs/blast_radius/ALL_TEST_01_PREFLIGHT.md`) committed
    first, before any test code.
- **Part 1 — per-type suites (Swift)** — `a7da90c`
  (`test(arialexiconlib): per-type swift-testing peer suites (Swift)`)
  - `AcceptanceTests.swift` (6 tests) — full 8-noun matrix via
    `Acceptance.verbs(for:)` with `Set<Verb>` equality (no ordering assumed),
    exhaustive `accepts(_:_:) == verbs(for:).contains` cross-check over every
    noun×verb pair, vector-accepts-none, learn/capture applicability, recall
    breadth.
  - `NounTests.swift` (6 tests) — `Noun.allCases.count == 8`, `primary ==
    .drawer`, per-case `role`, role partition 1/2/3/2, `NounRole.allCases.count
    == 4`, rawValue round-trip.
  - `VerbTests.swift` (6 tests) — `Verb.allCases.count == 9` (I-7) +
    declaration-order identity, per-case `flow`, flow partition 6/2/1,
    `Flow.allCases.count == 3`, rawValue round-trip.
  - `AdjectiveTests.swift` (3 tests) — `Adjective.allCases.count == 4` (I-8),
    the four category identities, rawValues. Thin by design — the Swift
    `Adjective` names categories, not values; no axis-value semantics invented
    (Known Ambiguity 1 resolved by reading source).
  - `LexiconTests.swift` left **intact** (Y1 → Option A): preserves all 9
    original assertions literally; serves as the cross-cutting conformance-anchor
    suite and the `AriaLexiconLib.grammar` top-level peer (`grammarStated`).
  - `Package.swift` **untouched** — swift-testing is available via
    `swift-tools-version: 6.0` (same as SubstrateTypes); a dependency would be a
    no-op (Smythe Finding 4).
- **Part 2 — parity confirmed** — `1ddc639`
  (`test(arialexiconlib): Swift/Rust library-test parity confirmed`)
  - BRR test-verification section filled with the parity table: every Rust
    behavior has ≥1 Swift peer; the Swift side asserts a superset. Nothing
    missing → no code added beyond confirmation.
- **Adams post-flight** — `173ed1e`
  (`docs(alltest): Adams post-flight — PASS CLEAN, hard gate satisfied`)

## Test Verification Log

### Baseline (mission start, commit b42db96 — Smythe-verified, Bilby-confirmed)
- `cd packages/libs/AriaLexiconLib && swift test`: exit 0, **9 tests in 1 suite**
  passed. (Mission's "0 tests in 0 suites" claim was false — see premise
  correction.)
- `cd rust && cargo test`: exit 0, **9 passed**.

### Final (commit 1ddc639 / 173ed1e)
- Command: `cd packages/libs/AriaLexiconLib && swift test`
  - Exit code: **0**
  - Pass count: **30 tests in 5 suites** (9 baseline + 21 new: Acceptance 6,
    Noun 6, Verb 6, Adjective 3)
  - Tail (verbatim): `Test run with 30 tests in 5 suites passed after 0.001 seconds.`
  - `swift build --build-tests` warnings: **0**; `warning:` lines in test output: **0**
- Command: `cd packages/libs/AriaLexiconLib/rust && cargo test`
  - Exit code: **0**
  - Pass count: **9** (unchanged — no Rust edit)
  - Tail (verbatim): `test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s`
  - `cargo` warnings: **0**
- `grep -rn "import XCTest" Tests/`: **no matches** (zero XCTest).

Coverage achieved: all 5 `Sources/AriaLexiconLib/` types (Acceptance,
AriaLexiconLib, Noun, Adjective, Verb) have a peer suite; supporting enums
(`NounRole`, `Flow`) covered in their owning type's suite. All 9 Rust `#[test]`
behaviors retain a Swift peer (parity table in BRR). Adjective remains thin by
design (no per-value surface exists in source — not a gap).

## Smythe Pre-flight

Verdict: **YELLOW — proceed**, no RESCOPE.
(`docs/blast_radius/ALL_TEST_01_PREFLIGHT.md`)
- **Premise mismatch (Finding 1):** `LexiconTests.swift` is already swift-testing
  (`import Testing`, `@Suite`, 9 `@Test`); the mission's XCTest claim is false.
  Part 1's "conversion" does not exist as a code task.
- **Finding 4:** Package.swift needs no swift-testing dep (tools-version 6.0). A
  change would be a no-op — do not touch it.
- **Finding 5:** No per-type peer coverage exists; all 4 CREATE files valid.
- Three YELLOW items, all Bilby's call, all honored: Y1 (LexiconTests restructure)
  → chose Option A (leave intact, preserve assertions literally); Y2 (Adjective
  thin by design) → honored; Y3 (use `Set<Verb>` equality, no ordering) → honored.
- Real blast radius corrected to 4 files (vs mission's 6), narrower not wider.

## Adams Post-flight

Verdict: **PASS — CLEAN.** Hard gate satisfied.
(`docs/blast_radius/ALL_TEST_01_POSTFLIGHT.md`)
- **Blast Radius Verification: PASS** — diff is exactly 7 files (4 new test files
  + 3 docs); no production source touched (`Sources/**`, `rust/**`,
  `Package.swift`, `docs/validation/**`, `LexiconTests.swift` all absent from the
  diff, confirmed by `git diff --name-only`). INTENTIONALLY_LEFT justifications
  for LexiconTests (Y1 Option A) and Package.swift (tools-version 6.0 no-op)
  verified.
- **Test Execution Verification: PASS (Method B re-run)** — independently re-ran
  both legs: swift exit 0 / 30 in 5 suites, cargo exit 0 / 9, both MATCH Bilby's
  claims; zero warnings both legs; zero `import XCTest`.
- **Implementation correctness:** every assertion in all 4 suites cross-checked
  line-by-line against source; matrix/role/flow/order values match the source
  case-for-case; `acceptsIsMembershipEverywhere` is non-tautological; Y2/Y3
  honored; all 5 types covered; all 9 Rust behaviors have a Swift peer.
- **Findings: zero CRITICAL, zero WARNING, zero INFO.**

## Self-review

- Diff (7 files: 4 new test files + BRR + preflight + postflight + mission file)
  matches the BRR MUST_UPDATE list exactly. Zero production source modified;
  `LexiconTests.swift` and `Package.swift` deliberately untouched and justified.
- No bridges, shims, TODOs, deprecations, secrets, or silenced warnings in the
  diff. No view/UI code, so no system colors / unlocalized strings to consider.
- New tests assert only behavior grounded in `Sources/` — no invented semantics
  (AdjectiveTests deliberately thin; no axis values). `Set<Verb>` equality used
  throughout the matrix so the Swift `Set` return type is honored without
  assuming the Rust `Vec` ordering.
- Blast Radius Report: `docs/blast_radius/ALL_TEST_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents — evaluated

- **Simms — NOT spawned.** Criterion = ships user-facing view/behavior change.
  This is a test-only mission (no app/view code, no behavior change, no MCP
  surface change). Nothing for a user guide.
- **Friedlander / Nert — N/A.** Not a UI mission (no views, no visual or
  accessibility surface).
- **Perkins — N/A.** No security surface: no schema change, no CloudKit sync, no
  FNode privacy fields, no API-key/Keychain/URL-scheme/NL-prompt handling. Test
  code over a behavior-free vocabulary library.
- **Nagatha docs-repo sync — deferred to post-merge** (standard: Nagatha syncs
  stream output after the mission lands). Per the operative goal directive, this
  completion report is written directly to `docs/status/` and the signal file
  follows.

## Discoveries

- **Mission premise was stale.** The XCTest→swift-testing conversion had already
  shipped (commit `719cb08`, `v0.8`). A future mission-authoring pass should
  re-verify file state against claims before writing the premise — Smythe caught
  it cleanly, but the mission text would have sent a literal-minded worker
  hunting for a `import XCTest` that does not exist. Recorded so the record is
  accurate; the delivered work (per-type peer suites) is exactly what the mission
  Files table and Test Requirements asked for.

## Outstanding (out of scope — not addressed)

- None. Both legs green, zero warnings, all success criteria met. Mission's
  Package.swift table entry intentionally left as a no-op (documented).
