# Smythe Pre-flight: SUBSTRATE_TYPED_LEVEL_CONVERGE_001

## Status
GREEN

## Status details
- Blast radius: verified — comment-only, no symbol renamed/removed/altered; blast radius protocol does not apply per skill (purely additive comments)
- Prior art: fc (TASK-MXC-2026-0034) merged at e002112 (stream/fc-forbidden-combo-converge) — dependency satisfied
- Environment: branch stream/tl-typed-level-converge, worktree clean; one untracked file (the mission file itself)
- Dependencies: satisfied

---

## Findings

**Claim 1 — Three canonical enums at stated lines.** VERIFIED. `Trust` at line 108 (already `Comparable`), `AdjectiveSensitivity` at line 134, `AdjectiveExportability` at line 150. Exactly three hits, all in `Adjectives.swift`. No class-B or class-D duplicates anywhere.

**Claim 2 — fc landed; Verbs.swift raw extractions gone.** VERIFIED. `Verbs.swift` now lives at `packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift` (post-fc move). Lines 488–502: `isLegalRowState` delegates entirely to `ForbiddenCombinations.check`. Zero raw extractions at the old ~490–492 site. fc dependency clean.

**Claim 3 — RowStateAutomaton.swift class-C extraction lines.** VERIFIED. Lines 252, 253, 263, 297 — exactly as stated. Four raw extractions, all inside `ForbiddenCombinations.check`. No surprises.

**Claim 4 — GeneratedColumn.swift class-C classification.** VERIFIED. Line 7 doc-comment contains `(adjective_bitmap >> 6) & 0x3F` as an illustrative example. LocusKit/Package.swift (lines 39, 49) shows LocusKit depends on PersistenceKit — the dependency is LocusKit → PersistenceKit, so PersistenceKit cannot import LocusKit. Class-C correct. One-line citation warranted in Part 2.

**Claim 5 — Provenance.swift `Sensitivity` is not a class-B duplicate.** VERIFIED. Bilby's classification holds. `Provenance.Sensitivity` at lines 178–183 is a distinct axis (sensitivity-at-capture, provenance bitmap bits 30–35, shift 30 width 6). The doc comment at line 172 already states it "mirrors adjective sensitivity raws." Not a duplicate — a parallel enum on a different bitmap column. No Part 3 action needed.

**Claim 6 — Stale comment at Adjectives.swift:127.** CONFIRMED. Line 127 says "a 2-bit contiguous encoding at bits 16–17 of the provenance column." Ground truth: `Provenance.swift` line 242 accessor uses `shift: 30, width: 6` — 6-bit scale-gapped at bits 30–35. The comment is wrong on width (2-bit vs 6-bit), contiguity (scale-gapped), and position (bits 16–17 vs 30–35). Bilby's intent to fix this in Part 1 is **in scope** — same file, comment-only, mandated by the comment-fidelity rule.

**Claim 7 — ForbiddenCombinationValidator.swift stale comment.** CONFIRMED. Line 45: "numeric encoding at bits 4–11 is the contract." Post-F11 the correct range is 6–17. File is on the MUST NOT modify list. Bilby's call to record it in the completion report's Outstanding section rather than edit the file is **correct**. File ownership is clear; defer is the right move.

**Part 3 — EMPTY as expected.** No class-B importable duplicate surfaced. Part 3 remains empty. Mission scope holds.

---

## Blockers
None.

---

## Bilby's stated approach
Part 1: add a header paragraph to `Adjectives.swift` naming `Trust`, `AdjectiveSensitivity`, and `AdjectiveExportability` as the single cross-kit source of truth, explaining why lower layers carry raw integers, and fixing the stale Provenance.Sensitivity description at line 127. Part 2: add one-line citation comments at `RowStateAutomaton.swift` lines 252–253, 263, 297 and at `GeneratedColumn.swift` line 7. Part 3: empty (no class-B duplicates). No logic, storage, bit-layout, or audit-wire change. Three files at most.

Assessment: accepted. Stale-comment fix in Part 1 is explicitly in scope per comment-fidelity rule. Deferred FCV stale comment is correctly handled. No surprises in the terrain.

---

## Actions (proceeding)
1. Part 1 — edit `Adjectives.swift`: header paragraph + fix line 127 stale description. `swift build` in LocusKit package. Pre-commit checklist.
2. Part 2 — edit `RowStateAutomaton.swift` (4 sites) and `GeneratedColumn.swift` (line 7 doc-comment). `swift build` in SubstrateLib and PersistenceKit packages. Pre-commit checklist.
3. Completion report — include Outstanding item: `ForbiddenCombinationValidator.swift:45` stale bit-range comment ("bits 4–11" should be "bits 6–17"); MUST NOT touch the file in this mission.
4. Write `.done-tl` signal to `/Users/bob/devlop/ddfactory/control/signals/.done-tl`.

GREEN. Terrain clear. Proceed.
