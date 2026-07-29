# Blast Radius Report — RG-DISCRIM (MISSION_11X_RECALL_GAP_01 Stream D)

**Baseline:**
- CorpusKit Swift: `swift test --package-path packages/kits/CorpusKit` → 412 tests, exit 0
- CorpusKit Rust: `cargo test` in `packages/kits/CorpusKit/rust` → 173 tests, exit 0
- GeniusLocusKit Swift: `swift test --package-path packages/kits/GeniusLocusKit` → 628 tests, exit 0

**Mission:** Saturation-aware discrimination signal (Item 3, MISSION_11X_RECALL_GAP_01).
Two halves: CorpusKit measures, GLK applies.

**Approach:** Purely additive changes on the CorpusKit side (new type + new function,
no existing symbol touched). One modified call site in RecallDirector.swift (Swift)
and coordinator.rs (Rust) — changing the call from `floatNearestPerSignal` to the
new `floatNearestPerSignalWithDiscrimination` and adding discount logic in the
matrixAware scoring formula.

**Symbols being changed:**

## Symbol 1: RecallDirector.unionBest — dense lane call site
**Change class:** semantic (call site change + new discount application)
**Scope:** internal (method on actor extension)
**File:** packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/RecallDirector/RecallDirector.swift

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| RecallDirector.swift | 1136 | grep | MUST_UPDATE | The call `corpus.floatNearestPerSignal(query:limit:)` changes to `floatNearestPerSignalWithDiscrimination` + discount application |

### Summary
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 0 sites
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 2: EstateCoordinator.recall_scored (Rust) — dense lane call site
**Change class:** semantic (call site change + new discount application)
**Scope:** internal (method on coordinator struct)
**File:** packages/kits/GeniusLocusKit/rust/src/coordinator.rs

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| coordinator.rs | 6724–6725 | grep | MUST_UPDATE | The call `c.float_nearest_per_signal(...)` changes to `float_nearest_per_signal_with_discrimination` + discount application |

### Summary
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 0 sites
- RESCOPE_REQUIRED: 0 sites

---

## Additive-only changes (no blast radius)

The following are purely additive and carry no blast radius:
- New struct `FloatDiscriminationSignal` (Swift: CorpusKit.swift)
- New method `Corpus.floatNearestPerSignalWithDiscrimination` (Swift: CorpusKit.swift)
- New method `CorpusContentEngine.floatNearestPerSignalWithDiscrimination` (Swift: CorpusContentEngine.swift)
- New struct `FloatDiscriminationSignal` (Rust: corpus.rs)
- New method `Corpus::float_nearest_per_signal_with_discrimination` (Rust: corpus.rs)
- New method `CorpusContentEngine::float_nearest_per_signal_with_discrimination` (Rust: content_engine.rs)
- `pub use corpus::FloatDiscriminationSignal;` in lib.rs

None of these touch or rename existing public symbols.

---

## Existing callers of floatNearestPerSignal — NOT changed

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| GLKScaleQual/main.swift | 142 | grep | INTENTIONALLY_LEFT | Diagnostic scale-qual tool; does not participate in recall fusion; reads the existing unmodified `floatNearestPerSignal` for analysis output |
| FloatLaneOutcomeTests.swift | 661, 702, 704 | grep | INTENTIONALLY_LEFT | Test existing API; the existing function is preserved unchanged; new tests added for the new function |
| DefaultEnsembleRecallPayoffTests.swift | 168 | grep | INTENTIONALLY_LEFT | Tests existing Corpus.floatNearestPerSignal which is preserved unchanged |
| NProviderTests.swift | 118, 139 | grep | INTENTIONALLY_LEFT | Tests per-signal recall on existing interface; preserved unchanged |

The existing `floatNearestPerSignal` function is preserved with identical semantics.
RecallDirector now uses the new `floatNearestPerSignalWithDiscrimination` which
returns the same outcomes PLUS the discrimination signal. The discrimination signal
computation adds no observable side effects.
