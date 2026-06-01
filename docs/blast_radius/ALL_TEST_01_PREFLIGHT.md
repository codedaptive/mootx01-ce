# Smythe Pre-flight: ALL-TEST-01

## Status

YELLOW — proceed. Mission premise contains one factual error that changes scope. Terrain otherwise
clear. No blockers. Rescope NOT required — the real work is additive-only (per-type suites), not
a conversion. Part 1 commit message needs updating; everything else in the mission is executable.

---

## Status details

- **Blast radius:** Mission declares 6 files (1 convert + 4 CREATE + 1 conditional Package.swift).
  Reality: Package.swift change is NOT needed (swift-testing already wired via tools version 6.0).
  Real blast radius is 5 files: LexiconTests.swift (8 existing @Test methods, already swift-testing,
  suite restructure only) + 4 CREATE files. Blast radius claim is slightly over-scoped on Package.swift;
  otherwise accurate.
- **Prior art:** No conflicting prior art. No partial per-type suites exist. Only one test file present.
- **Environment:** Branch `stream/al-arialexiconlib-test-leg` active. Source tree clean (one untracked
  mission file only). No baseline broken.
- **Dependencies:** None. Mission declares parallel-safe with eidetic-test, engram-test, substrate
  test missions (disjoint packages). Confirmed — AriaLexiconLib/Tests is self-contained.

---

## Mission-premise mismatch — MUST READ before coding

### Finding 1 — CRITICAL PREMISE ERROR: LexiconTests.swift is already swift-testing

Mission claims: "The Swift library test leg is a single `LexiconTests.swift` with 9 methods using
`import XCTest` — which violates the project standard and registers as '0 tests in 0 suites'."

**Reality, verbatim from the file:**

```
LexiconTests.swift:8    import Testing
LexiconTests.swift:11   @Suite("AriaLexiconLibTests")
LexiconTests.swift:12   struct AriaLexiconLibTests {
```

No `import XCTest` anywhere. The file uses `import Testing`, declares a `@Suite`, and has 8 `@Test`
methods (not 9 — see Finding 2). The XCTest conversion described in Part 1 is already done. Part 1
as written does not exist as a code task.

### Finding 2 — Method count: 8 @Test methods, not 9

Mission claims 9 methods. Actual `@Test` count in LexiconTests.swift: **8**.

Methods present:
1. `verbCountIsNine` — "The verb count is fixed at nine (I-7)"
2. `adjectiveCountIsFour` — "The adjective category count is fixed at four (I-8)"
3. `drawerIsPrimary` — "The drawer is the one noun of the language"
4. `nonDrawerShapesHaveRoles` — "Every non-drawer shape is a rung, structure, or product"
5. `verbFlowsPartition` — "Verb flows partition the nine verbs as the spec defines"
6. `acceptanceMatrix` — "Acceptance matrix matches spec section 7.2"
7. `acceptsAgrees` — "accepts agrees with the verb set"
8. `verbApplicability` — "Only the learnedReference accepts learn; only the drawer and tunnel accept capture"

Missing from mission claim: `grammarStated` IS present — it is the 9th test function visible in
the file. Re-read: the file has 9 `@Test` functions total including `grammarStated` at line 87.
Count corrected to **9** — mission count is accurate. The discrepancy was a read-order artifact.
Final: 9 `@Test` methods confirmed.

### Finding 3 — Rust: 9 `#[test]` functions confirmed

`grep -c '#\[test\]'` on `rust/src/lib.rs` returns **9**. Mission claim accurate.

Rust test names (lines 155–240 of lib.rs):
1. `verb_count_is_nine`
2. `adjective_count_is_four`
3. `drawer_is_primary`
4. `non_drawer_shapes_have_roles`
5. `verb_flows_partition`
6. `acceptance_matrix`
7. `accepts_agrees`
8. `verb_applicability`
9. `grammar_stated`

Swift and Rust test names align 1:1. Parity already structurally present at the suite level.

### Finding 4 — Package.swift: no explicit swift-testing dependency, and none needed

AriaLexiconLib/Package.swift uses `swift-tools-version: 6.0`. Under Swift 6 tooling, the Testing
framework is available to test targets with zero manifest changes — same pattern as SubstrateTypes,
which also has no explicit Testing dependency in its Package.swift. `LexiconTests.swift` compiles
against `import Testing` already. The "conditional: additive swift-testing dep only if absent"
Package.swift change in the mission file table is a no-op. Do not touch Package.swift.

### Finding 5 — Per-type coverage: none exists, 4 CREATE files needed

Tests directory contains exactly one file: `LexiconTests.swift`. No peer coverage for Acceptance,
Noun, Adjective, or Verb. All four CREATE entries in the mission table are valid and needed.

---

## Sources verified

| File | Public types |
|---|---|
| `Sources/AriaLexiconLib/AriaLexiconLib.swift` | `enum AriaLexiconLib` (static `grammar: String`) |
| `Sources/AriaLexiconLib/Acceptance.swift` | `enum Acceptance` (`verbs(for:)`, `accepts(_:_:)`) |
| `Sources/AriaLexiconLib/Noun.swift` | `enum Noun: CaseIterable` (8 cases + `primary`/`role`), `enum NounRole` (4 cases) |
| `Sources/AriaLexiconLib/Adjective.swift` | `enum Adjective: CaseIterable` (4 cases: state/trust/sensitivity/exportability) |
| `Sources/AriaLexiconLib/Verb.swift` | `enum Verb: CaseIterable` (9 cases), `enum Flow` (3 cases: callerDriven/substrateDriven/groundingDriven) |

Supporting enums in scope: `NounRole` (in Noun.swift) and `Flow` (in Verb.swift). Both are public.

---

## Blast radius — real vs claimed

| File | In mission table? | Required? | Notes |
|---|---|---|---|
| `Tests/AriaLexiconLibTests/LexiconTests.swift` | yes (convert) | MODIFY — suite restructure only | Already swift-testing. 9 @Test methods. May want to split Acceptance tests to AcceptanceTests.swift; existing tests can stay or migrate. |
| `Tests/AriaLexiconLibTests/AcceptanceTests.swift` | yes (CREATE) | CREATE | No file exists. |
| `Tests/AriaLexiconLibTests/NounTests.swift` | yes (CREATE) | CREATE | No file exists. |
| `Tests/AriaLexiconLibTests/AdjectiveTests.swift` | yes (CREATE) | CREATE | No file exists. |
| `Tests/AriaLexiconLibTests/VerbTests.swift` | yes (CREATE) | CREATE | No file exists. |
| `Package.swift` | yes (conditional) | NO-OP — do not touch | swift-testing available via tools-version 6.0; no dep needed. |

Real blast radius: **5 files** (1 possible restructure + 4 CREATE). Package.swift: 0 changes.

---

## Blockers

None.

---

## YELLOW items — Bilby must decide before writing

### Y1 — LexiconTests.swift: restructure or leave in place

The existing 9 tests in `LexiconTests.swift` cover Acceptance, Noun, Adjective, Verb, and
AriaLexiconLib surface. The 4 CREATE suites will add per-type peer coverage. Two options:

**Option A:** Leave LexiconTests.swift as-is (existing integration suite). Author the 4 CREATE
files as additional focused suites. Some assertions will overlap — that is acceptable (belt-and-
suspenders on grammar invariants).

**Option B:** Migrate tests from LexiconTests.swift into the per-type suites, leave LexiconTests
empty or containing only cross-type integration assertions (like `grammarStated`).

Mission says "preserve 9 assertions." Option A satisfies that by definition. Option B also
preserves them by migration. No right answer — choose before writing. State the choice in the
stated approach below.

### Y2 — Adjective: no per-case behavioral surface to test

`Adjective` is a 4-case enum with no computed properties beyond `allCases` and raw value. The Rust
`Adjective::ALL` test only checks count == 4. The per-type `AdjectiveTests.swift` will be thin
by design — that is correct, not a gap. Do not invent semantics not in source.

### Y3 — Acceptance matrix return type: Set<Verb> vs ordered Vec<Verb>

Swift `Acceptance.verbs(for:)` returns `Set<Verb>`. Rust `accepted_verbs()` returns `Vec<Verb>` in
canonical verb order. The existing `acceptanceMatrix` test in LexiconTests.swift correctly uses
`==` on `Set<Verb>` — no order dependency. When writing AcceptanceTests.swift, use `Set` equality
throughout; do not assume order.

---

## What the real remaining work is

The mission premise ("XCTest conversion") is already done. The real mission is:

1. Author 4 per-type suites (Acceptance, Noun, Adjective, Verb) as CREATE files covering the
   behaviors the Rust `#[test]` functions assert.
2. Optionally restructure LexiconTests.swift (per Y1 above).
3. No Package.swift change needed.
4. Verify `swift test` registers non-zero (already does, given existing file is swift-testing).
5. Verify `cargo test` green (9 expected).

Part 1 commit message in the mission ("swift-testing conversion + per-type suites") is inaccurate
as written. Correct commit message: `test(arialexiconlib): per-type test suites (AcceptanceTests, NounTests, AdjectiveTests, VerbTests)`

---

## Bilby's stated approach

**Y1 → Option A.** Leave `LexiconTests.swift` exactly as-is (it is already swift-testing
and already registers; this literally satisfies "preserve 9 assertions" with zero risk of
dropping one). CREATE the 4 per-type peer suites (`AcceptanceTests`, `NounTests`,
`VerbTests`, `AdjectiveTests`). Each mirrors the relevant Rust `#[test]` behaviors AND adds
type-local depth the combined suite does not assert — so the new files earn their place
rather than being pure duplicates: `NounTests` adds `Noun.allCases.count == 8`, full
per-case `role`, role-partition counts, `NounRole.allCases`, and rawValue identity;
`VerbTests` adds `allCases.count == 9` + ordering, per-case `flow`, flow-partition counts,
`Flow.allCases`, rawValue identity; `AcceptanceTests` adds the full 8-noun matrix using
`Set<Verb>` equality (Y3 honored — no ordering assumed) plus an exhaustive
`accepts == verbs(for:).contains` cross-check over every noun×verb pair; `AdjectiveTests`
is thin by design (Y2 honored — `allCases` count/identity/rawValues only, no invented
axis-value semantics — the Swift `Adjective` has none). AriaLexiconLib top-level surface
(`grammar`) stays covered by `LexiconTests.grammarStated`. NOT doing: any Package.swift
change (no-op per Finding 4); any Sources/** or rust/** edit; any LexiconTests deletion.

Assessment: approach is consistent with the YELLOW verdict and all three YELLOW items
(Y1/Y2/Y3). Proceeding.

---

## Actions (proceeding)

1. Decide Y1 (restructure vs leave LexiconTests.swift as-is). State it. Proceed with that choice.
2. Read the 9 Rust tests in `lib.rs:152-241` to confirm behavioral surface before writing any Swift.
3. CREATE `AcceptanceTests.swift` — cover `verbs(for:)` per-noun and `accepts(_:_:)` spot checks.
   Use `Set<Verb>` equality; do not depend on ordering.
4. CREATE `NounTests.swift` — cover `Noun.primary == .drawer`, `role` per case, `allCases` count (8),
   filter-by-role counts. `NounRole` coverage belongs here too.
5. CREATE `VerbTests.swift` — cover `allCases.count == 9`, `flow` per case, partition by flow,
   `Flow.allCases.count == 3`.
6. CREATE `AdjectiveTests.swift` — cover `allCases.count == 4`, raw values present. Thin by design.
7. If restructuring LexiconTests.swift (Option B): migrate relevant tests, leave cross-type suite.
8. Run `swift test` — must exit 0, register >= 9 tests (will be significantly more after CREATE files).
9. Run `cargo test` from `rust/` — must exit 0, 9 passed.
10. Zero warnings both legs.

---

## Decision needed

None from Bob. YELLOW items are Bilby's call. Path is clear.

Bilby's stated-approach field must be filled before coding starts.

---

## Verdict

**YELLOW. Terrain substantially clear. Proceed with corrected premise.**

The XCTest->swift-testing conversion claimed in the mission is already done in the codebase.
Real work: 4 CREATE files + optional LexiconTests restructure. No rescope required — scope is
narrower than claimed, not wider. RESCOPE_REQUIRED is NOT triggered. Bilby starts at "Author
per-type suites" — Part 1 as labeled is already complete.
