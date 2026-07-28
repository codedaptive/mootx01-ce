# Blast Radius Report — W1_DISTILL

**Mission:** SPEC_DISTILLATION_STORAGE.md (Wave 1) — distilled representation
as drawer-row columns; `moot_distill` rename; factoid-tier retirement;
`moot_recall_distilled` reimplementation; search isolation.
**Stream:** stream/w1-distillation
**Spec (contract):** mootx01-ee `docs_internal/specs/SPEC_DISTILLATION_STORAGE.md` v0.1
**Codegraph:** indexed (fresh `codegraph init` this session); callers/impact
queries used for code call sites, rg for non-code references.
**Note:** Appendix A (migration from frozen 1.0.x) is explicitly OUT of this
mission — a separate later mission. No migration code is written here. The
2026-07-28 correction to Appendix A step (a) (sources are NOT superseded by
factoids) affects only that future mission; the §11 retirement work here is
unaffected.

## Step 0 — Baselines (all exit 0 at mission start)

### Swift (`swift test`, per-target "Test run with N tests" summaries)

| Package | Pass count |
|---|---|
| SubstrateML | 487 |
| LocusKit | 836 + 8 = 844 |
| PersistenceKit | 78+151+35+38+171+25+1 = 499 |
| CorpusKit | 396 |
| GeniusLocusKit | 628 |
| CognitionKit | 230 |
| AriaMcpKit | 23 + 554 = 577 |
| VaultKit | 192 |
| NeuronKit | (baseline captured before Part 2 — lens surface changes there) |

### Rust (`cargo test`, all `test result: ok`, zero failed)

| Crate | Result lines (passed) |
|---|---|
| substrate_ml | 298, 18, 2, 21, 0 |
| locus_kit | 730, 11, 4, 53, 19 |
| persistence_kit | 174, 17, 5, 5, 5 |
| corpus_kit | 23, 2, 8, 11, 5 |
| genius_locus_kit | 131, 5, 17, 13, 4 |
| cognition_kit | 193, 1, 10, 0 |
| aria_mcp_kit | 46, 24, 232, 5, 8 |

All suites green at mission start; the gate at mission end is exit 0 with
pass counts at or above these numbers (minus tests deleted WITH the retired
surfaces they test, plus new tests).

---

## Symbol 1: `drawers` table schema — four representation columns (§4)

**Change class:** additive columns + semantic (content-writing sites gain
NULL-on-edit representation clearing)
**Scope:** public (schema + `Drawer` entity)

New nullable columns `distilled` TEXT, `distilled_pipeline_version` TEXT,
`distilled_token_count` INTEGER, `distilled_at` TIMESTAMP(TEXT ISO8601).
No Bool columns; no migration ladder (schema FLUID on 1.1.x — no estates in
the field; columns land in the v1 declaration per the schema file's own
design note).

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/LocusKit/Sources/LocusKit/LocusKitSchema.swift (drawersTable) | read | MUST_UPDATE | add 4 columns |
| packages/kits/LocusKit/rust/src/schema.rs (drawers_table) | read | MUST_UPDATE | twin |
| packages/kits/LocusKit/Sources/LocusKit/Drawer.swift | read | MUST_UPDATE | 4 stored optional fields + Codable |
| packages/kits/LocusKit/rust/src/drawer.rs | read | MUST_UPDATE | twin |
| packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift | read | MUST_UPDATE | drawerValues/drawerFromRow; new `setDistilledRepresentation`; NULL-clear at every `content`-writing update (expunge ×3, updateDatasetContent) |
| packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs + sqlite drawer-store twin | rg | MUST_UPDATE | twin row mapping + setter + clear-on-content-write |
| packages/kits/PersistenceKit/Sources/PersistenceKit/RowCrypto.swift | read | MUST_UPDATE | §2 at-rest parity: `distilled` joins `content` in the Mode-2 row-crypto seam (encrypt/decrypt/invariant guard) |
| packages/kits/PersistenceKit/rust row-crypto twin (row_store.rs / sqlite.rs) | rg | MUST_UPDATE | twin |
| LocusKit + PersistenceKit tests (new) | — | MUST_UPDATE | round-trip, atomic 4-column write, NULL-on-edit, erasure scrub, crypto cover |
| packages/kits/LocusKit/Sources/LocusKitEstateFixture/TwentyRowEstateFixture.swift | rg | INTENTIONALLY_LEFT | fixture builds Drawers via init with defaulted nil representation fields — compiles unchanged |

Erasure-contract note (defense in depth, §2): `distilled` is content-derived
text, so every site that zeroes `content` (expunge head, tombstoned-sibling
re-zero, gate-rejected sibling scrub) and `updateDatasetContent` must NULL
the four representation columns in the same statement.

## Symbol 2: `DistillationOutput.drawerContent` → `distilledText`; `[DIST|]` header + `DistilledHeader` retirement (§5, §11.3)

**Change class:** rename + semantic (rendering becomes token-economical
prose, zero inline metadata) + removal (`DistilledHeader` and all consumers)
**Scope:** public

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/libs/SubstrateML/Sources/SubstrateML/DistillationPipeline.swift | codegraph+read | MUST_UPDATE | Stage 5 rendering; field rename; DistilledHeader deleted; short-item/§7.6 helpers |
| packages/libs/SubstrateML/rust/src/distillation_pipeline.rs | codegraph | MUST_UPDATE | twin |
| packages/libs/SubstrateML/Sources/SubstrateML/TypedDecayWeighting.swift | rg ("[DIST|") | MUST_UPDATE | comment references header format — comment fidelity |
| packages/libs/SubstrateML/Tests/SubstrateMLTests/DistillationPipelineTests.swift | rg | MUST_UPDATE | header-format tests replaced by rendering tests |
| packages/libs/SubstrateML/Tests/SubstrateMLTests/DistillationConformanceTests.swift + rust/tests/distillation_conformance.rs | rg | INTENTIONALLY_LEFT | Reclassified post-implementation (Adams-verified): these suites pin the MATH stages (DeltaFeatureExtractor, decay weighting, SNR, confidence, fingerprints) — none of which changed. The Stage 5 rendering is covered by NEW §13.9 vectors (TokenCompactionConformanceTests / token_compaction_conformance.rs + the lens rendering vectors); both legacy suites pass unmodified against the new pipeline. |
| packages/kits/NeuronKit/Sources/NeuronKit/Lenses/Distillation.swift | rg | MUST_UPDATE | lens surfaces drawerContent; rename ripples; injection-depth metadata stays generation-time-only (§5.2) |
| packages/kits/NeuronKit/rust/src/distillation.rs (+ lib.rs re-export) | rg | MUST_UPDATE | twin |
| packages/kits/NeuronKit/Tests/…/DistillationLensTests.swift, DistillationLensConformanceTests.swift, rust/tests/distillation_lens_conformance.rs | rg | MUST_UPDATE | field/format assertions |
| packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift | rg | MUST_UPDATE | runMemorySearch `_distilled` preview branch + `injectionDepthFormatted` + `distilledProseCap` retire (§11.3) |
| packages/kits/AriaMcpKit/Tests/AriaMCPTests/InjectionDepthFormattingTests.swift | codegraph | MUST_UPDATE | deleted with the formatter |
| packages/kits/AriaMcpKit/rust/src/tool_list.rs + recipe_tools.rs (format prose) | rg | MUST_UPDATE | descriptions reference header/factoids |
| docs/validation/substrate_math_performance/test-harness/check-lockstep.py | rg | INTENTIONALLY_LEFT | Reclassified post-implementation (Adams-verified): the lockstep harness audits TYPE parity of the math-stage primitives, not the rendering string — unaffected by the drawerContent→distilledText rename and header retirement. |
| apps/mcp-benchmarker/results/*.md, docs/status/FAB5_*.md | rg | INTENTIONALLY_LEFT | frozen historical result/status records |

## Symbol 3: `GeniusLocusKit.distillItem` / `distillItemsSweep` / `captureFactoid` (§7, §11.1–.5)

**Change class:** semantic (writes 4 columns + re-keyed lane entry; no drawer,
no tunnel, no lineage side effects) + removal (`captureFactoid`), signature
(distillItem return), eligibility predicate becomes `distilled IS NULL` or
pipeline-version mismatch
**Scope:** public (GLK verb surface)

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Brain/DistillationCycle.swift | codegraph | MUST_UPDATE | full rewrite per §7.2/§7.4/§7.5 |
| packages/kits/GeniusLocusKit/rust/src/coordinator.rs (distill_items_sweep, find_nearest_distilled docs) | rg | MUST_UPDATE | twin rewrite |
| packages/kits/GeniusLocusKit/rust/src/brain/distillation_cycle.rs | rg | MUST_UPDATE | factoid constants/helpers retire; new column-write helpers |
| packages/kits/GeniusLocusKit/rust/tests/distill_segmentation_parity.rs | rg | MUST_UPDATE | asserts factoid capture parity — rewrites to column parity |
| packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/DistillationCycleTests.swift | codegraph | MUST_UPDATE | new contract tests |
| packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/DistillationSignalTests.swift | rg | MUST_UPDATE (verify) | signal wrapper unchanged; comments/diagnostics wording |
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Brain/Signals/DistillationSignal.swift + DefaultStandingSignals.swift | rg | MUST_UPDATE | comment fidelity ("factoids produced" → items distilled) |
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Intake/EncodeIntake.swift + EstateLifecycle.swift (wireCorpusRoomRollup) | read | MUST_UPDATE | drain-stage distillation wiring (§7.1) + distillFn registry |
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Verbs/VerbSurface.swift (findNearestDistilled doc) | rg | MUST_UPDATE (comments) | lane retained (§8); recall-route comments corrected |
| packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/FindNearestDistilledTests.swift | codegraph | MUST_UPDATE (verify) | lane key now source drawer id — assertions may hold; verify |
| packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/StandingSignalsTests.swift | rg | INTENTIONALLY_LEFT unless wording assertions fail | tests scheduler, not sweep semantics |
| packages/kits/VaultKit/Sources/VaultKit/DrawerMapping.swift + rust/src/drawer_mapping.rs | rg | MUST_UPDATE | `_distilled_from` export/import frontmatter path retires (§11.2 — a new-write path) |
| packages/kits/VaultKit/Tests (PrivacyTierAndReceiptTests, VaultBridgeTests) + rust/tests/charter_and_provenance.rs, palace_pump_units.rs | rg | MUST_UPDATE | tunnel-mapping tests retire/adjust |

## Symbol 4: `Consolidate` recipe → `Distill`; tool `moot_consolidate` → `moot_distill` (+alias) (§3)

**Change class:** rename (recipe name "distill", output field
`factoidsProduced` → items-distilled) + alias retention
**Scope:** public (MCP tool surface — both legs together)

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/CognitionKit/Sources/CognitionKit/Consolidate.swift | codegraph | MUST_UPDATE | recipe rename + new sweep semantics + extractor pinning (see §Design notes) |
| packages/kits/CognitionKit/rust/src/consolidate.rs + catalog.rs | rg | MUST_UPDATE | twin + registration |
| packages/kits/CognitionKit/Sources/CognitionKit/RecipeCatalog.swift | rg | MUST_UPDATE | registration |
| packages/kits/CognitionKit/Tests/CognitionKitTests/ConsolidateTests.swift, DistillationIntegrationTests.swift | rg | MUST_UPDATE | renamed + new assertions |
| packages/kits/AriaMcpKit/Sources/AriaMCP/RecipeTools.swift | read | MUST_UPDATE | primary listing moot_distill; moot_consolidate dispatch alias; output text |
| packages/kits/AriaMcpKit/rust/src/recipe_tools.rs + tool_list.rs | rg | MUST_UPDATE | twin |
| packages/kits/AriaMcpKit/Sources/AriaMCP/TeachmeGuides.swift | rg | MUST_UPDATE | guides reference consolidate/distilled tools |
| packages/kits/AriaMcpKit/Tests (RecipeToolsTests, ToolProjectionTests, LensToolsTests, V1ConformanceTests) | rg | MUST_UPDATE | tool roster assertions |
| apps/mootx01/Sources/MootInstallerCore/PermissionsWriter.swift (+ its tests) | rg | MUST_UPDATE | permission tool list gains moot_distill |
| apps/mootx01/…/Generated/EmbeddedArtifacts.swift + apps/mootx01/rust/src/embedded/install-bundle.json | rg | MUST_UPDATE | regenerate via their generator (generated files — not hand-edited) |
| docs/reference/ARIA_MCP_SPEC.md | rg | MUST_UPDATE | tool documentation |
| apps/mcp-benchmarker (main.swift, Config.swift) | rg | MUST_UPDATE (verify) | tool-name references in client protocol |

## Symbol 5: `DistilledRecall` reimplementation (§10)

**Change class:** semantic — exact-search geometry (same recall request as
`moot_memory_search`) + distilled hydration + fallback marker + per-hit token
counts; Hamming-NN route retired
**Scope:** public

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/CognitionKit/Sources/CognitionKit/DistilledRecall.swift | codegraph | MUST_UPDATE | full reimplementation |
| packages/kits/CognitionKit/rust/src/distilled_recall.rs | rg | MUST_UPDATE | twin |
| packages/kits/CognitionKit/Tests/CognitionKitTests/DistilledRecallTests.swift | rg | MUST_UPDATE | |
| packages/kits/AriaMcpKit/Sources/AriaMCP/RecipeTools.swift (runRecallDistilled + descriptor) | read | MUST_UPDATE | new output shape incl. distilled_token_count + fallback notice |
| packages/kits/AriaMcpKit/rust/src/recipe_tools.rs | rg | MUST_UPDATE | twin |
| GLK `HydrationRepresentation` (new, + TokenCompaction consumers) | — | MUST_UPDATE (additive) | §10.1 selector, four variants, computed at read |
| apps/mcp-benchmarker LongMemEvalRunner.swift / LongMemEvalScorer.swift / token_efficiency_vectors.json (+ rust twins) | rg | MUST_UPDATE (verify) | dense-arm parser of moot_recall_distilled output |

## Symbol 6: `Recollect` recipe + `moot_recollect` retirement

**Change class:** removal. With the factoid tier gone, distilled hits ARE the
source drawers — the fan-out is `moot_memory_get` on the same id. The tunnels
and header it depends on both retire (§11.2, §11.3).
**Scope:** public

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/CognitionKit/Sources/CognitionKit/Recollect.swift + Tests/RecollectTests.swift + RecipeCatalog | codegraph+rg | MUST_UPDATE | delete + dereg |
| packages/kits/CognitionKit/rust/src/recollect.rs + catalog.rs | rg | MUST_UPDATE | twin |
| packages/kits/AriaMcpKit RecipeTools.swift + rust recipe_tools.rs + tool_list.rs + TeachmeGuides + tests | rg | MUST_UPDATE | tool removal |
| installer permission lists + embedded artifacts (as Symbol 4) | rg | MUST_UPDATE | regenerate |

NOTE: `moot_recollect` retirement is an inference from §11 (its entire
substrate — factoid drawers, `_distilled_from` tunnels, DIST header — is
retired by the spec; the tool cannot function). Called out in the completion
report as a spec-silent decision for Bob's review.

## Symbol 7: `CorpusContentEngine` drain accounting (§7.1, §9)

**Change class:** semantic — `onEncoded`/`fire_on_encoded` moves BEFORE the
terminal `queue.reply`, so post-encode coordination (room rollup + drain-stage
distillation) is covered by drain-completion accounting ("a fully drained
estate is a fully distilled estate").
**Scope:** internal (engine queue)

| File | Source | Classification | Justification |
|---|---|---|---|
| packages/kits/CorpusKit/Sources/CorpusKit/CorpusContentEngineQueue.swift | read | MUST_UPDATE | reorder + comment |
| packages/kits/CorpusKit/rust/src/content_engine_queue.rs | rg | MUST_UPDATE | twin (incl. reply-failure test at :645 if ordering-sensitive) |
| CorpusKit tests asserting reply/callback ordering | rg | MUST_UPDATE (verify) | |

§9 search isolation requires NO CorpusKit indexer change: the digest is
`CorpusContentDigest.digest(content)` and every indexer read set is content
only. Representation writes are direct row-store column updates that emit no
`ContentIndexJob`. Proven by the §13.3 geometry probe test (new), not by code
change.

## Symbol 8: new shared primitives (additive)

`TokenCompaction` (§7.6 one pure transform), token-count estimator (§6),
`DistillationPipelineVersion.current == "p1"` — SubstrateML Swift + Rust with
golden conformance vectors; `HydrationRepresentation` (GLK); GLK per-estate
distillFn registry. Additive files; no existing call sites.

## Symbol 9: T5 exit check — encode-drain-only gate (PERF_W1_DRAIN_RIDER Finding 3)

**Change class:** semantic (the T5 finisher spawn/exit predicate narrows from
"any drain isDraining" to "the corpus_encode drain isDraining") + additive
helper `DrainStatus.encodeSettled` / `DrainStatus::encode_settled` +
`corpusEncodeName` / `CORPUS_ENCODE_NAME` constant.
**Scope:** public (GLK) / app commands.

### Call sites (`isDraining` / `is_draining` consumers)

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| apps/mootx01/Sources/mootx01/Commands/ServeCommand.swift | 350 | grep | MUST_UPDATE | the Finding 3 spawn condition |
| apps/mootx01/Sources/mootx01/Commands/DrainCommand.swift | 113 | grep | MUST_UPDATE | the lease-holding poll loop |
| apps/mootx01/rust/src/commands/drain.rs | 73 | grep | MUST_UPDATE | Rust twin of the poll loop |
| apps/mootx01/rust/src/commands/serve.rs | 294 | grep | INTENTIONALLY_LEFT | Rust T5 spawn uses `encode_queue_has_pending` (maildir check on the encode queue dirs) — already encode-only, unaffected by drain statuses |
| packages/kits/AriaMcpKit/.../ToolDispatch.swift | 2824 | grep | INTENTIONALLY_LEFT | `moot_drain_status` display formatting — reporting all drains is the tool's contract |
| packages/kits/AriaMcpKit/rust/src/interface_tools.rs | 2703 | grep | INTENTIONALLY_LEFT | same display twin |
| packages/apple/MootIntentKit/.../HeavyVerbCore.swift | 30–106 | grep | INTENTIONALLY_LEFT | separate DrainSnapshot type parsed from tool TEXT output; display/summary only, holds no lease |
| apps/mcp-benchmarker EncodeBarrier.swift / encode_barrier.rs | — | grep | INTENTIONALLY_LEFT | benchmarker barrier parses tool text and settles on all-lanes-idle; it holds no lease and its behavior on 1.1.x estates with never-swept system drawers is a benchmarker-methodology question flagged in the completion report, out of this fix's sanctioned scope |
| packages/kits/GeniusLocusKit/.../DistillationDrainStageTests.swift | 215, 224 | grep | INTENTIONALLY_LEFT | asserts the distillation entry itself; unaffected |
| packages/kits/AriaMcpKit/rust/src/estate_registry.rs | 54 | grep | MUST_UPDATE | additive `pub use genius_locus_kit::DrainStatus` re-export so drain.rs can name the type |

### Summary
- MUST_UPDATE: 60+ sites across 9 packages + 2 apps (enumerated above)
- INTENTIONALLY_LEFT: frozen results/status docs; TwentyRowEstateFixture;
  StandingSignalsTests (conditional)
- RESCOPE_REQUIRED: 0 — the mission is sanctioned wave-scale ("spec is the
  contract"; parts adjusted by implementer per orders)

## Design notes recorded for review

1. **Extractor pinning ("p1").** §5.3 rule 6 requires the stored rendering to
   be a deterministic function of (content, pipeline version), bit-identical
   Swift/Rust. The §7.4 core-first sentence ordering depends on the feature
   extractor; Swift sweeps currently inject the NeuronKit HMM extractor while
   the Rust sweep uses `DistillationPipeline::default_extractor` — divergent.
   Contract "p1" therefore pins `defaultExtractor` (present and bit-identical
   on both legs) for the distillation write path. This also makes the stored
   fingerprints self-consistent with `queryFingerprint`, which already used
   the default extractor. Flagged in the completion report.
2. **§7.4 "episodic tail compresses hardest"** is implemented as: one §7.6
   compaction transform applied to all sentences; core sentences (those
   carrying dominant-component features) render first in stable source order,
   tail after. Rule 1 (propositional fidelity, priority 1) forbids a lossier
   tail transform, so "hardest" is bounded by the same rule set. Flagged.
3. **Erasure scrub** of representation columns at every content-zeroing site
   is a §2 consequence (derived text must not outlive erased content).
