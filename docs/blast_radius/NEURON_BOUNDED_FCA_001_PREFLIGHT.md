# Smythe Pre-flight: NEURON_BOUNDED_FCA_001

**Branch:** `stream/fa-bounded-fca`
**Baseline:** `8cad620`
**Date:** 2026-06-01

---

## Status

YELLOW

---

## Status details

- **Blast radius:** verified — three target files absent (confirmed), lib.rs present
  with `association_rule_mining` already registered at line 49; `fa` adds line 27 of
  `pub mod` declarations; no parallel-stream collision on lib.rs from any sibling
  worktree (fc, mt, hd checked).
- **Prior art:** FCA symbols clean — `FormalAttribute`, `FormalConcept`,
  `FormalContext`, `BoundedConceptMiner`, `formal_concept` absent across all Swift
  and Rust source under `packages/`. **One exception: `RowID` — see Warning below.**
- **Environment:** clean — worktree on `stream/fa-bounded-fca`, baseline `8cad620`;
  `git status` shows only the mission file as untracked. BRR-documented test counts
  trusted (Swift 138/17 suites, Rust 143, both exit 0).
- **Dependencies:** satisfied — no `Package.swift` or `Cargo.toml` change needed;
  new Swift source lands in existing NeuronKit target; `pub mod formal_concept_analysis;`
  is the sole lib.rs edit.

---

## Blockers

None. Mission may proceed.

---

## Warning — `RowID` name collision on Swift public surface

**File:** `packages/kits/LocusKit/Sources/LocusKit/EstateTypes.swift:15`
**Symbol:** `public typealias RowID = String`

LocusKit exports `RowID` publicly, and NeuronKit imports LocusKit as a direct
module dependency (`Package.swift` line 57/82). Two NeuronKit source files already
use bare `RowID` from that import:

- `NeuronKit/Sources/NeuronKit/Dreaming/DreamingDaemon.swift` (lines 87, 90, 98, 100, 137, 308, 409, 432)
- `NeuronKit/Sources/NeuronKit/Maintenance/MaintenanceSeams.swift` (lines 45, 52, 53)

The mission proposes adding `RowID` as a public typealias (`UInt32`) in
`FormalConceptAnalysis.swift`. If declared `public`, the NeuronKit module would
expose two `RowID` declarations at its public surface — a collision. Even if
`internal`, files in NeuronKit that `import LocusKit` and reference `RowID` would
face an ambiguity (Swift reports "ambiguous use of 'RowID'" when two imported names
clash).

**Rust side is clean.** `locus-kit` exports `pub type RowID = String` (Rust), but
Rust module scoping isolates it: `formal_concept_analysis.rs` defines its own local
`type RowID = u32` without ambiguity so long as it does not `use locus_kit::RowID`.
No Rust action needed.

**Resolution (Swift — Bilby chooses one):**

Option A (recommended): rename to `FCARowIndex` — a type-local name that cannot
collide, clearly scoped to the FCA engine, and equally comprehensible in conformance
tests. Use `FCARowIndex` everywhere the mission text says `RowID`.

Option B: declare `typealias RowID = UInt32` as `private` or `internal` inside
`FormalConceptAnalysis.swift` only. Removes the public surface collision. Acceptable
if tests use `FCARowIndex` as a public test alias or access via the concrete
`FormalConcept.extent` type (`[UInt32]`).

Option C: drop the typealias entirely and use `UInt32` directly in `FormalConcept`
and `FormalContext`. Minimal friction. The "context-local index" concept is
communicated by the field names (`extent`, row indexing) without a named alias.

The BRR lists `RowID` as a new public symbol. That listing must be corrected
whichever option Bilby takes.

**This is a warning, not a blocker.** The FCA engine file itself will not import
LocusKit (per mission: no estate, no LocusKit), so `FormalConceptAnalysis.swift`
has no ambiguity internally. Bilby can resolve this by choosing a name before
writing the first line, at zero extra cost.

---

## Verification findings

### 1. File paths and existence

| File | Path resolves? | Already exists? |
|---|---|---|
| `FormalConceptAnalysis.swift` | yes — `packages/kits/NeuronKit/Sources/NeuronKit/` | absent — CREATE clear |
| `FormalConceptAnalysisTests.swift` | yes — `packages/kits/NeuronKit/Tests/NeuronKitTests/` | absent — CREATE clear |
| `formal_concept_analysis.rs` | yes — `packages/kits/NeuronKit/rust/src/` | absent — CREATE clear |
| `rust/src/lib.rs` | yes | present — EDIT (one-line registration) |

### 2. Symbol collision — FCA names

Grep across all Swift and Rust source under `packages/`:
`FormalAttribute`, `FormalConcept`, `FormalContext`, `BoundedConceptMiner`,
`formal_concept` — **zero hits**. Clean.

### 3. Symbol collision — `RowID`

Swift: `LocusKit/EstateTypes.swift:15` — `public typealias RowID = String`.
LocusKit is a direct NeuronKit module import. Two NeuronKit source files use bare
`RowID` resolved from that import. See Warning above.

Rust: `LocusKit/rust/src/estate_types.rs:17` — `pub type RowID = String`. The
`neuron-kit` crate depends on `locus-kit` (Cargo.toml line 29), but Rust module
isolation prevents collision in `formal_concept_analysis.rs` as long as the file
does not `use locus_kit::RowID`. No action needed.

### 4. Rust lib.rs — registration state

`lib.rs` at baseline (`8cad620`): 26 `pub mod` declarations including
`pub mod association_rule_mining;` at line 49 (the `ar` stream landed in main
at baseline). `fa` adds `pub mod formal_concept_analysis;` as line 27. The
ar/fa lib.rs write hazard flagged in the mission is moot in this worktree.

Sibling worktrees:
- `mootx01-ce-fc-forbidden-combo-converge` — lib.rs at 189 lines (pre-`ar` baseline);
  no `formal_concept` in lib.rs. No collision.
- `mootx01-ce-mt-matrixt-lifecycle-audit` — lib.rs at 189 lines (pre-`ar`); no FCA
  registration. No collision.
- `mootx01-ce-hd-nary-association-adr` — lib.rs at 189 lines (pre-`ar`); no FCA
  registration. No collision.

This worktree's lib.rs is at 190 lines (post-`ar`). No parallel-stream lib.rs write
collision currently exists.

### 5. Conformance pattern

`mmr_rank.rs` carries inline `#[cfg(test)] mod tests` (line 127). No `rust/tests/`
directory exists (`packages/kits/NeuronKit/rust/tests/` — absent, confirmed).
`MMRRankTests.swift` uses `import Testing`, `@Suite`/`@Test`/`#expect`.
Both patterns verified. Mission correctly calls for the same approach.

### 6. Package.swift — no change needed

New Swift files land in the existing `NeuronKit` library target (confirmed: target
declared with a source directory, not an explicit file list). No `Package.swift` edit
required.

### 7. Cargo.toml — no change needed

`formal_concept_analysis.rs` imports stdlib only per mission spec. No new crate
dependency. No `Cargo.toml` edit required.

### 8. Anti-pattern suite

- **Unlocalized strings:** N/A — pure engine, no UI.
- **Accessibility:** N/A — no UI.
- **Date storage:** N/A — no persistence.
- **Bool stored properties on entities:** N/A — result types carry bitsets and sorted
  arrays per spec.
- **Secrets:** N/A — pure math.
- **Deprecated vocabulary:** none.
- **AI calls in FulcrumKit:** N/A — NeuronKit is not FulcrumKit.
- **Geometric layout directions:** N/A — no UI.
- **Exponential path check:** mission specifies closure from single-attribute seeds
  only; no full lattice enumeration; stability omitted in v1 (field present,
  always nil). No exponential path. Verified against BRR bounding guarantees section.

### 9. Estate coupling — confirmed absent

Engine imports nothing from LocusKit, SubstrateTypes, or GeniusLocusKit. Pure
stdlib both legs. `Adjectives.swift` is reference-only per mission; not imported.

---

## Bilby's stated approach

Pure bitset-backed `FormalContext` built from `[[FormalAttribute]]` rows. Closure =
`intent(extent(intent))`. `BoundedConceptMiner` seeds from frequent single attributes
only, one closure per seed, deduplicate by intent, sort support desc → intent size
asc → lexicographic intent key, truncate to `maxConcepts`. `stability` field present
in `FormalConcept` but always `nil` in v1 — no subset enumeration anywhere. No
estate, no `MatrixO`, no `Adjectives` import on either leg.

**Assessment:** accepted. Approach is polynomial, deterministic, matches the mission
spec and BRR bounding guarantees. The sole look-before-write item is the `RowID`
name — resolve it before writing line one of `FormalConceptAnalysis.swift`.

---

## Actions (proceeding order)

1. **Resolve `RowID` naming before writing.** Choose `FCARowIndex` (recommended),
   `internal typealias`, or bare `UInt32`. Whichever is chosen, use it consistently
   in both Swift and Rust files.
2. Implement `FormalConceptAnalysis.swift` — `FormalAttribute`, row-index type,
   `FormalConcept`, `FormalContext`, closure operators. Commit:
   `feat(fa): formal context + closure operators (bitset-backed)`.
3. `cd packages/kits/NeuronKit && swift build` — must exit 0.
4. Implement `FormalConceptAnalysisTests.swift` — all required cases per Part 3 spec.
   Commit: `test(fa): swift unit tests for bounded FCA`.
5. `cd packages/kits/NeuronKit && swift test 2>&1 | tail -20` — must exit 0; record
   pass count (baseline 138 + new).
6. Implement `formal_concept_analysis.rs` + register in `lib.rs`. Inline
   `#[cfg(test)] mod tests` encoding the same cases as Swift. Commit:
   `feat(fa): rust port of bounded FCA with inline conformance tests`.
7. `cd packages/kits/NeuronKit/rust && cargo test` — must exit 0; record pass count
   (baseline 143 + new).
8. Write signal file to `/Users/bob/devlop/ddfactory/control/signals/.done-fa`.
9. Spawn Adams for post-flight.

---

## Decision needed

**`RowID` naming — Bilby decides before writing.** Recommendation: `FCARowIndex`.
No Bob or orchestrator action required; this is an implementation choice within
Bilby's lane. Noting here so Adams checks it at post-flight: the public NeuronKit
surface must not expose two `RowID` declarations.
