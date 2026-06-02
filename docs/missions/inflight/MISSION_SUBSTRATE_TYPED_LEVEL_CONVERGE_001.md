# Mission SUBSTRATE_TYPED_LEVEL_CONVERGE_001 — Make LocusKit's Adjective-Level Enums the Documented Cross-Kit Source of Truth

## Priority: P1
## Stream: tl
## Branch from: main
## Depends on: fc (TASK-MXC-2026-0034)
## Parallel safe with: `ar`, `fa`. NOT parallel-safe with `fc`.

---

## Context

**Tree.** This mission targets **mootx01-ce**, base branch **main**.

**The typed levels already exist and are canonical** (verified against CE source). `LocusKit/Adjectives.swift` defines `Trust` (line 108, already `Comparable` on rawValue: verbatim 0 … canonical 3 … ambient 6), `AdjectiveSensitivity` (line 134: normal 0, elevated 16, restricted 32, secret 48), and `AdjectiveExportability` (line 150: private 0, public 32). NeuronKit and GeniusLocusKit read these. **This mission must not create a fourth copy** — that is the duplication it exists to prevent. `Trust: Comparable` — the council's headline addition — is **already shipped**. Nothing is added there.

**The layering rules out the council's design** (verified): `LocusKit/Package.swift` depends on SubstrateLib, not the reverse. So "create the enums in SubstrateTypes and have the gate derive `legalValues` from them" is **impossible** — SubstrateTypes/SubstrateLib sit *below* LocusKit and cannot import its enums. Relocating the enums down would divorce them from their cookbook home and `Drawer` accessors and rewrite every NeuronKit/GLK import, justified by nothing here. **So `tl` is a convergence-and-documentation mission, not an enum-creation mission.**

**Part 0 was pre-run by the team against CE; the implementer reconfirms it. The finding shrinks this mission to comment-only:**
- **No duplicate level enums exist anywhere.** `grep` for `enum Trust|enum AdjectiveSensitivity|enum AdjectiveExportability` returns only the three canonical definitions in `LocusKit/Adjectives.swift`. **Class B (importable duplicate → replace with import): none. Class D (non-importable duplicate → record/recommend): none.**
- The only *other* representation of these axes is **raw-integer extraction** (`(adjective >> 6/12/18) & 0x3F`) in code that cannot import LocusKit — **class C**. Those sites get a one-line citation comment; the raw integer stays as the cross-layer contract, exactly as `ForbiddenCombinationValidator` already documents about itself.
- Class-C **source** sites: `SubstrateLib/RowStateAutomaton.swift` (`ForbiddenCombinations.check`, ~lines 252–253, 263, 297). **Candidate:** `PersistenceKit/Sources/PersistenceKit/GeneratedColumn.swift` (a bitmap-layout doc-comment) — classify in Part 0. Raw-shift assertions in **test files** are not citation targets.

**Why this depends on `fc`.** `fc` rewrites `Verbs.swift`'s `isLegalRowState` to delegate to `ForbiddenCombinations.check`, **deleting its raw extractions at `Verbs.swift:490–492`.** Those lines are NOT citation targets for this mission — `fc` removes them. `tl` must run **after** `fc` so the implementer cites only the *surviving* extraction sites (`RowStateAutomaton.swift`), never lines `fc` is about to delete. This is the whole reason for the dependency; the two missions edit disjoint files (`fc`: `Verbs.swift`; `tl`: `RowStateAutomaton.swift` + `Adjectives.swift`), but `tl`'s correct scope depends on `fc` having landed.

**Comment-only. ≤3 existing files. No symbol is renamed, removed, or has its semantics changed — there is no call-site blast radius to chase.** The diff is one header paragraph plus citation comments. No behavior, storage, bit-layout, or audit-wire change. Edit count within the Tier 1 cap (≤3).

## Read First
- `LocusKit/Adjectives.swift` — the canonical enums (READ; the source of truth; receives a header paragraph).
- `SubstrateLib/RowStateAutomaton.swift` — `ForbiddenCombinations.check` raw extractions (class-C; receive citations). Read the **post-`fc`** state of the package.
- `LocusKit/ForbiddenCombinationValidator.swift` — the model for the class-C citation comment ("the numeric encoding is the contract; the enum names are documentation"). READ ONLY.
- `PersistenceKit/Sources/PersistenceKit/GeneratedColumn.swift` — candidate class-C site; classify it.

## Mandatory Part 0 — Duplicate-and-citation audit (against the CE tree; do this first)
From the CE repo/worktree root:
```
grep -rn --include=*.swift --exclude-dir=.build -E "enum (Trust|AdjectiveSensitivity|AdjectiveExportability)\b" packages/
grep -rn --include=*.swift --exclude-dir=.build -E "enum [A-Za-z]*(Sensitivity|Exportability|Trust)[A-Za-z]* *:" packages/   # shadow enums
grep -rn --include=*.swift --exclude-dir=.build -E ">> 6\) & 0x3F|>> 12\) & 0x3F|>> 18\) & 0x3F" packages/                  # raw extraction
```
Classify each hit: (A) the canonical LocusKit enum; (B) a true duplicate enum in a layer that *can* import LocusKit → replace with import; (C) a raw extraction in a layer that *cannot* import LocusKit → cite, keep the raw; (D) a duplicate in a non-importable layer → record and recommend, do not relocate. **Expected from the team's pre-run: A = the three in `Adjectives.swift`; B and D = none; C = `RowStateAutomaton.swift` (+ `GeneratedColumn.swift` if it resolves to a representation site).** If Part 0 contradicts this (a duplicate enum surfaces in any layer), STOP and surface it — the comment-only scope no longer holds. Test-file shift assertions are excluded.

## Blast Radius Scope
Comment-only. No symbol renamed, removed, or altered in semantics, so there is no call-site chase.

**Files (Part 0-authoritative):**
- `LocusKit/Adjectives.swift` — header paragraph (comment-only).
- `SubstrateLib/RowStateAutomaton.swift` — citation comments at the `ForbiddenCombinations.check` raw extractions (comment-only).
- `PersistenceKit/Sources/PersistenceKit/GeneratedColumn.swift` — one-line citation **only if** Part 0 classifies it class-C; else omit.

No class-B replacement (no importable duplicate exists). No class-D entry (no duplicate exists). Tests: none changed (no behavior change).

## Files You Will Modify
- `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift` — source-of-truth header paragraph.
- `packages/libs/SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift` — citation comments at the raw extractions.
- (conditional) `packages/kits/PersistenceKit/Sources/PersistenceKit/GeneratedColumn.swift` — one-line citation, only if Part 0 classifies it class-C.

## Files You MUST NOT Modify
- The raw integer encodings themselves (the integers are the cross-layer contract — comments only, no value changes).
- `Verbs.swift` (`fc` owns it; its raw extractions are removed by `fc` — do not add citations there).
- `ForbiddenCombinationValidator.swift` logic (its citation is already present).
- Any `Package.swift` to add a LocusKit dependency to a lower layer (that inverts the graph — forbidden).
- Adjective bitmap shifts/widths. Audit wire format. `docs/concepts/`. Test files.

## Implementation Parts

### Part 1 — Mark LocusKit's enums the documented source of truth
Add a header paragraph to `Adjectives.swift` stating that `Trust`, `AdjectiveSensitivity`, and `AdjectiveExportability` are the single source of truth for the three adjective axes across all kits; that lower layers (SubstrateLib, SubstrateTypes) carry the raw-integer encoding as the cross-layer contract because they cannot import LocusKit; and that any new representation of these axes must either import these enums or cite them. Comment-only.

**Commit:** `docs(tl): mark LocusKit adjective-level enums as cross-kit source of truth`
→ verify: `cd packages/kits/LocusKit && swift build`; run the pre-commit checklist.

### Part 2 — Cite the canonical enums from the class-C raw sites
At each raw extraction in `ForbiddenCombinations.check` (and `GeneratedColumn.swift` if Part 0 classifies it class-C), add a one-line comment, e.g. `// raw 48 = AdjectiveSensitivity.secret; raw 32 = AdjectiveExportability.public; LocusKit/Adjectives.swift is source of truth (cannot import: layer below LocusKit)`. No logic change.

**Commit:** `docs(tl): cite LocusKit level enums from SubstrateLib raw forbidden-combination checks`
→ verify: `cd packages/libs/SubstrateLib && swift build`; run the pre-commit checklist.

### Part 3 — Replace any class-B duplicate with an import (EMPTY)
Part 0 found no duplicate level enum in any layer that can import LocusKit, so this part is empty and the BRR states so. If Part 0 contradicts that finding, STOP and surface it rather than proceeding — the mission scope changes.

## Test Requirements
Citation-only mission: SubstrateLib + LocusKit (and PersistenceKit if touched) build and their suites remain green; no behavior assertions change.

## Test Verification Log

### Baseline (mission start, post-`fc`)
- Pass count at mission start for each touched package: NNN (must exit 0; else STOP, write `.stuck`).

### Final
- Command: `cd packages/<pkg> && swift test 2>&1 | tail -20` for each touched package
- Exit code: 0
- Pass count: NNN (unchanged — no behavior assertions changed)
- Tail output (verbatim): …

## Verification
Touched packages build and test green. Grep: no duplicate level enums in any layer that can import LocusKit (confirmed none); every class-C source extraction site carries a citation. Run self-review against the BRR's MUST_UPDATE list. Spawn Adams for post-flight: no enum created in SubstrateTypes; no LocusKit dependency added to a lower layer; the diff is comments plus one header paragraph only; no behavior change; `Trust: Comparable` left as-is (already present); `Verbs.swift` untouched.

## Success Criteria
1. LocusKit's `Trust`/`AdjectiveSensitivity`/`AdjectiveExportability` are the documented single source of truth; no fourth copy is created anywhere.
2. Every class-C source extraction site cites the canonical enum; Part 0 confirms no class-B importable duplicate exists (Part 3 empty) and no class-D non-importable duplicate exists.
3. No behavior, storage, bit-layout, or audit-wire change; the dependency graph is not inverted; the diff is comment-only.
4. `Trust: Comparable` confirmed already present; nothing added there.
5. `Verbs.swift` is not touched (`fc` owns it; its raw extractions are removed by `fc` and are not citation targets for this mission).

## Non-goal / follow-on
Relocating the enums to a lower layer; `FinitePoset`/`meet`/`join`; deriving `legalValues` from the enums at the gate (impossible under current layering — would require the enums to live below SubstrateLib, a separate architectural decision). The poset follow-on remains federation-motivated.

## Signal File
Write to: `/Users/bob/devlop/ddfactory/control/signals/.done-tl`
