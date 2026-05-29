# Upstream Staging

Files moved here during the SubstrateLib promotion (2026-05-19) because they belong to upstream kits in the eleven-kit family, not to SubstrateLib itself.

These files are preserved so the subsequent kit refactor missions can pick them up. They are not currently part of any built target; they exist as reference material.

| File | Target kit | Target mission |
|---|---|---|
| `glref-swift-ActuatorKit.swift` | NeuronKit (algorithm layer) | Mission 9 |
| `glref-swift-CognitionKit.swift` | NeuronKit reasoning functions plus CognitionKit recipes | Missions 9 and 10 |
| `glref-swift-DreamingDaemon.swift` | GeniusLocusKit Brain layer | Mission 8 |
| `glref-swift-PortableCognitionBundle.swift` | NexusKit or CognitionKit | TBD during mission 10 or 11 |
| `glref-swift-SQLiteDurabilityTail.swift` | PersistenceKit-SQLite | **DONE 2026-05-19** — DDL/PRAGMA content ported to SQLiteConnection.swift; in-memory reference store superseded by InMemoryAuditLog |
| `glref-swift-WorkingSetMmap.swift` | **GeniusLocusKit Brain layer** | Mission 8 — bit-tensor persistence is matrix-tier substrate concern, not storage abstraction; lives with ThreeDBitTensor usage |

## Why staged rather than left in GeniusLocusReference

The reference implementation at `docs/validation/substrate_math_performance/GeniusLocusReference/` remains the authoritative cookbook-cross-reference source. These files were in that reference because the cookbook covers their content as part of the substrate's mathematical and operational story. They were moved out of the SubstrateLib promotion path because they implement upstream behavior (algorithms, recipes, daemon ecology, storage internals) that does not belong in the substrate math kit.

Staging them in this directory preserves them at a clearly-marked location that subsequent missions can promote into the correct kit. Leaving them in GeniusLocusReference would have implied they should be part of SubstrateLib, which is the wrong layering.

## Note on RecallTypes

Four types were extracted from `glref-swift-CognitionKit.swift` and moved DOWN into SubstrateLib (not up to staging): RecallScore, DistanceBreakdown, RecallResult, and RowProjection. These are substrate-layer wire types that federation (TierAscendingQuery) and downstream cognition both consume; keeping them in SubstrateLib avoids redefinition drift across kits. The extraction is in `/Users/bob/devlop/mootx01/SubstrateLib/Sources/SubstrateLib/RecallTypes.swift`.

When `glref-swift-CognitionKit.swift` is promoted into NeuronKit and CognitionKit during missions 9 and 10, the type definitions for RecallScore, DistanceBreakdown, RecallResult, and RowProjection MUST be removed from the upstream file (it should import them from SubstrateLib instead).
