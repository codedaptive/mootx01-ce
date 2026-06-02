# MatrixT Lifecycle Audit

**Mission:** MATRIXT_LIFECYCLE_AUDIT_001 · **Date:** 2026-06-01 · **Tree:** mootx01-ce @ main

## Verdict

**(c) Partially-wired — held but unfed, and additionally unread.** `SubstrateTypes.MatrixT` is a fully implemented, unit-tested, Rust-mirrored type that no production code path writes, reads, decays, or persists. The estate (`Substrate`) holds a `matrixT` field that is initialized once and never touched again; no verb feeds it and no consumer queries it. The mission's listed "GLK consumers" do **not** consume `MatrixT` at all — those were substring matches (`MatrixTier`, `MatrixTemporalKey`, `MatrixDecay`, `MatrixPersistence`). GLK carries its own *parallel* temporal-causality store (`MatrixTier.temporalCausality`), which is itself fed only by tests: its sole feed primitive `applyTemporalEvent` has no production caller, and its decay (`applyDecay`) has zero callers anywhere, tests included. The prior assumption "MatrixT is unpopulated" was directionally right but understated: there are *two* temporal-causality implementations, both awaiting the dreaming-daemon pass that would feed them, and they disagree on bucket convention and (in docs) on half-life.

## Findings

### 1. Definition and shape — confirmed
- `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixT.swift:84` — `MatrixT: Sendable, Equatable`; sorted sparse entries. Key: `CausalityKey(sourceField, sourceValue, targetField, targetValue, lagBucket 0..7)` (`MatrixT.swift:43`), packed `UInt64` ordering (`MatrixT.swift:71`).
- Lag buckets `[1,2,4,8,16,32,64,128]` min (`MatrixT.swift:89`), `maxLagMinutes 256` (`MatrixT.swift:94`); bucket = largest edge ≤ minutes (`MatrixT.swift:99`). API: `count` (143), `increment` (167), `applyPair` (191), `reset` (210), `writeWire` (219), `readWire` (230).
- Decay is **doc-only** in the type: header claims half-life 90 days (`MatrixT.swift:31-33`); no decay method exists on `MatrixT`.
- Rust parity exists: `packages/libs/SubstrateTypes/rust/src/matrix_t.rs` (5 `#[test]`).

### 2. Write path — definitively: no verb feeds MatrixT
- `packages/libs/SubstrateLib/Sources/SubstrateLib/Verbs.swift:83` declares `public var matrixT: MatrixT`; `Verbs.swift:93` initializes it. **These are the only two references to the instance in the entire repo** (no `.matrixT` access anywhere else; `apps/` has zero hits).
- capture updates F (`Verbs.swift:141-147`) and O (`Verbs.swift:154`); mutate updates F (`250-261`) and O (`263-267`); expunge updates F (`335-341`) and O (`343`). **None touch T.** `MatrixT.applyPair`/`increment` have no callers outside `SubstrateTypesTests`.
- This matches the documented design: T is meant to be updated weekly by the dreaming daemon over audit-log row pairs (`MatrixT.swift:24-29`) — that daemon pass does not exist yet.
- Classification: **test-only** (neither live-verb-fed nor GLK-training-fed).

### 3. Read path — the listed "consumers" never read MatrixT
GLK has an independent T representation: `MatrixTier.temporalCausality: [MatrixTemporalKey: Int64]` (`packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Matrix/MatrixTier.swift:158`). Exact-name `MatrixT\b` and `CausalityKey` appear nowhere in GLK. Per file:
- **MatrixTier.swift** — holds the parallel store; feed primitive `applyTemporalEvent` (`MatrixTier.swift:255`, window ≤ 256 min via `temporalWindowMinutes`, `MatrixTier.swift:173`) → `addT` (`MatrixTier.swift:439`). **Only callers: `MatrixTierTests.swift:132,136`.** `rebuild(from:)` (`MatrixTier.swift:329`) replays the audit log into F/O only — it never feeds T.
- **EnrichmentPipeline.swift** — reads `temporalCausality.count` before/after a pass (`EnrichmentPipeline.swift:171,292`) to report `tKeysTouched`; since nothing in the pass calls `applyTemporalEvent`, the delta is structurally always 0.
- **TrainingDaemon.swift** — `runOnce` (`TrainingDaemon.swift:201`) threads `tier: inout MatrixTier` through the pipeline; touches T only transitively (i.e., not at all).
- **ThresholdGate.swift** / **AuditBridge.swift** — mention `MatrixTier` only in comments (`ThresholdGate.swift:22`, `AuditBridge.swift:7`); no T data access.
- **MatrixPersistence.swift** — persists `MatrixTier` (Codable) inside `MatrixSnapshot` (`MatrixPersistence.swift:58`), so `temporalCausality` round-trips structurally; no production caller (`MatrixPersistenceBackend` is used only by `MatrixTierTests`). `apps/ARIA_MCP` uses none of these types.
- Degradation if T stays empty: nothing degrades today — no query path (graph edges §7.1, anomaly z-score §8.13) reads either T store yet.

### 4. Decay — defined-but-uncalled, with a half-life doc conflict
- `MatrixTier.applyDecay` (`MatrixTier.swift:287`, default `tHalfLifeDays: 90.0`) is the only executable T decay; **zero callers repo-wide, including tests.**
- `SubstrateTypes.MatrixT` has no decay member; the 90-day figure is comment-only (`MatrixT.swift:31-33`).
- `packages/libs/SubstrateML/Sources/SubstrateML/MatrixDecay.swift` is a generic `DecayingMatrix` (well-tested) that never binds to either T store — and its cookbook table says **T τ = 30 days** (`MatrixDecay.swift:22`), contradicting the 90-day figure in `MatrixT.swift:31` and `MatrixTier.swift:285-291`. Reconcile before wiring.

### 5. Persistence — no estate snapshot includes MatrixT
- `MatrixT.writeWire`/`readWire` have **no callers outside `SubstrateTypesTests`** — there is no estate-snapshot path that serializes any `Substrate` matrix (the `Substrate` struct is the in-memory reference; `Verbs.swift:74-76`).
- The only matrix persistence is GLK's `MatrixSnapshot` (`MatrixPersistence.swift:58`, `load` 99 / `save` 141 / `rebuild` 182), which persists the *parallel* tier, not `MatrixT` — and cold-start `rebuild` replays the audit log through a path that feeds F/O only, so **a persisted T would survive reload via the snapshot file but could never be reconstructed from the log**.
- What survives a restart today: nothing T-related, on either implementation.

### 6. Test coverage — what's locked vs. not
- `SubstrateTypesTests/MatrixTTests.swift` (5 tests, lines 14–66): lag-bucket boundaries, `applyPair` cross-product, out-of-range no-op, asymmetry, wire round-trip. Locks the *type contract* only.
- `GeniusLocusKitTests/MatrixTierTests.swift`: `temporalLagBucketing` (124) locks the tier's feed primitive + window; `snapshottedModeRoundTripsExactly` (195) locks snapshot round-trip (with an empty T, however — entries are captures only).
- **Not locked anywhere:** verb→T write path (doesn't exist), decay-over-time (`applyDecay` untested), T-in-rebuild, T-populated persistence round-trip.
- Divergence the tests *do* lock in: the two implementations bucket differently — `MatrixT.lagBucket(3) → index 1` (round down, `MatrixT.swift:99`) vs `MatrixTier.lagBucket(3) → 4` (round up to boundary, `MatrixTier.swift:273`, locked by `MatrixTierTests.swift:126`).

## To activate for sequential mining (minimal)

1. **Pick one T store** (or define an explicit bridge): `SubstrateTypes.MatrixT` (estate) vs `MatrixTier.temporalCausality` (GLK). Two unfed parallel implementations with different key types and bucket conventions is the real blocker.
2. **Wire the feed:** implement the dreaming-daemon pair-mining pass (`MatrixT.swift:24-29`) over the audit log — iterate row pairs with `0 < Δt < 256 min`, call `applyPair`/`applyTemporalEvent`. The verbs themselves should *not* feed T (per design); the daemon should.
3. **Call decay:** schedule `applyDecay` (or a `MatrixT` equivalent) from the daemon tick; first reconcile the 30-day (`MatrixDecay.swift:22`) vs 90-day (`MatrixT.swift:31`) half-life conflict.
4. **Persist:** either include T in the chosen snapshot path with rebuild-from-log support (today `rebuild` cannot reconstruct T), or accept snapshot-only durability and document it.
5. **Lock it:** add tests for the daemon feed, decay-over-time, and a T-populated persistence round-trip — none exist today.
