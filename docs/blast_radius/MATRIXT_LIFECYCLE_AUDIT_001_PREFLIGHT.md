# Smythe Pre-flight: MATRIXT_LIFECYCLE_AUDIT_001

## Status

YELLOW

## Status details

- Blast radius: verified — all claimed source files exist at corrected paths
- Prior art: none conflicting — no existing memo covers MatrixT lifecycle
- Environment: clean — branch `stream/mt-matrixt-lifecycle-audit`, no uncommitted source changes
- Dependencies: satisfied — no prerequisites stated; this is a read-only scout

---

## Path correction (WARNING — not a blocker)

Mission states memo output path:

```
docs/_internal/workhistory/analysis/MATRIXT_LIFECYCLE_AUDIT.md
```

That path does NOT exist in this repo. Neither `docs/_internal/` nor `docs/_internal/workhistory/` exist, and no reference to these paths appears anywhere in docs.

The repo's actual analysis directory: `docs/analysis/` — which exists and contains `blast_radius/` (two files from a prior VK stream).

**Resolution required before writing the memo.** Bilby must write to one of:
1. `docs/analysis/MATRIXT_LIFECYCLE_AUDIT.md` — fits the existing `docs/analysis/` convention.
2. The mission's stated path, creating `docs/_internal/workhistory/analysis/` as new structure.

Option 1 is consistent with what's already in the repo. Option 2 creates an entirely new directory tree that has no precedent in this repo. Bob needs to confirm which path before the memo is written, OR Bilby picks `docs/analysis/` as the defensible default.

This is a YELLOW, not RED. Bilby can proceed with the audit work; memo path choice does not block reading code.

---

## Resolved real file paths

All six GLK consumer files and both test files confirmed present. Corrected `packages/libs/...` prefix applies to all source paths (mission uses bare `libs/...`).

| Mission claim | Real path |
|---|---|
| `libs/SubstrateTypes/Sources/SubstrateTypes/MatrixT.swift` | `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixT.swift` |
| `SubstrateLib/Verbs.swift` | `packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift` |
| `Matrix/MatrixTier.swift` | `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Matrix/MatrixTier.swift` |
| `Training/EnrichmentPipeline.swift` | `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Training/EnrichmentPipeline.swift` |
| `Training/TrainingDaemon.swift` | `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Training/TrainingDaemon.swift` |
| `Training/ThresholdGate.swift` | `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Training/ThresholdGate.swift` |
| `Audit/AuditBridge.swift` | `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Audit/AuditBridge.swift` |
| `Matrix/MatrixPersistence.swift` | `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Matrix/MatrixPersistence.swift` |
| `SubstrateTypesTests/MatrixTTests.swift` | `packages/libs/SubstrateTypes/Tests/SubstrateTypesTests/MatrixTTests.swift` |
| `GeniusLocusKitTests/MatrixTierTests.swift` | `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/MatrixTierTests.swift` |

---

## Blast-radius verification

**Central claim confirmed.** Searched SubstrateLib/Sources/ for any call to `applyPair` or `.matrixT` beyond declaration and initialization:

- `Verbs.swift:83` — `public var matrixT: MatrixT` (declaration)
- `Verbs.swift:93` — `self.matrixT = MatrixT()` (init)
- No other hits in SubstrateLib

`applyPair` and `increment` appear only in Verbs.swift comments referencing F-matrix and O-matrix operations (lines 138, 149, 550) — none reference `matrixT`. The preliminary finding is accurate: the estate's `matrixT` is declared and initialized but never written by capture/mutate/expunge.

---

## Prior art

No existing memo or analysis document covers MatrixT lifecycle. Existing docs mentioning MatrixT:
- `docs/reference/SUBSTRATETYPES_SPEC_v0.8.md` — spec definition
- `docs/reference/SUBSTRATETYPES_INTERFACE_v0.8.md` — interface
- `docs/reference/GENIUSLOCUSKIT_SPEC_v0.8.md` / `GENIUSLOCUSKIT_INTERFACE_v0.8.md` — consumer-side
- Various completion and blast-radius files referencing MatrixT in test contexts

No prior lifecycle audit. No ADR contradicts the mission. No conflict.

---

## Parallel stream conflicts

Active inflight missions: MISSION_ALL_TEST_01, MISSION_CK_TEST_01, MISSION_CVK_TEST_01, MISSION_ENGRAM_TEST_01, MISSION_GLK_TEST_01, MISSION_LK_TEST_01, MISSION_MCP_TEST_01, MISSION_NOUN_ASC_01, MISSION_PK_TEST_01, MISSION_QK_TEST_01, MISSION_SLIB_TEST_01, MISSION_SML_TEST_01, MISSION_VERB_REA_01, MISSION_VK_TEST_01.

Active branches: `stream/ar-assoc-rule-mining`, `stream/dd-datalog-rule-eval`, `stream/fc-forbidden-combo-converge`.

This mission is read-only and reserves only the memo path. No branch touches `docs/analysis/` or `docs/_internal/`. No conflict.

---

## Blockers

None. YELLOW is driven entirely by the memo output path mismatch — not a code blocker, not a read-blocker. Bilby can begin reading immediately.

**Action required before writing the memo:** confirm output path. Recommended: `docs/analysis/MATRIXT_LIFECYCLE_AUDIT.md`.

---

## Bilby's stated approach

_To be filled by Bilby before proceeding._

Smythe's read of the mission: grep-based trace of write path (`applyPair`/`increment` on estate `matrixT` through capture/mutate/expunge verb chain); read-path map of 6 GLK consumers; decay application search; persistence round-trip check (`writeWire`/`readWire` in estate snapshot vs GLK `MatrixPersistence`); test-coverage summary; then a one-page memo with verdict (live / GLK-only / partially-wired).

Pre-flight assessment: central question is already partially answered — no `applyPair`/`increment` on `matrixT` in SubstrateLib. The write-path finding will almost certainly land as "partially-wired" or "held but unfed." Parts 2 and 3 remain for Bilby to execute.

---

## Actions (if proceeding)

1. Confirm memo output path — `docs/analysis/MATRIXT_LIFECYCLE_AUDIT.md` is recommended; mission's `docs/_internal/workhistory/analysis/` path requires creating new directory structure with no repo precedent. Get Bob's call or default to `docs/analysis/`.
2. Read `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixT.swift` — confirm shape, lag buckets, decay declaration.
3. Read `packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift` in full — confirm write-path verdict definitively.
4. Read all six GLK consumers for read-path map.
5. Search for decay application: grep `halfLife\|decayFactor\|applyDecay\|matrixT` across GeniusLocusKit and SubstrateLib.
6. Check estate snapshot: search `writeWire\|readWire` in Verbs/estate snapshot path.
7. Read both test files for coverage assessment.
8. Write memo at confirmed path.
