---
version: v0.1
status: complete
created: 2026-07-28
stream: w1-distillation
implementer: Newton
spec: mootx01-ee docs_internal/specs/SPEC_DISTILLATION_STORAGE.md v0.1
---

# W1_DISTILL — Completion Report

Wave-1 distillation-storage rebuild on 1.1.x: distilled representations
as nullable columns on the drawer row, the token-economical §5 format,
drain-stage generation, search isolation, `moot_distill` + alias,
`moot_recall_distilled` as exact-search geometry + distilled hydration,
and the factoid-tier retirement. Swift and Rust twins landed together in
every commit; conformance vectors byte-identical across legs.

## Commits (stream/w1-distillation, never pushed)

| SHA | Part |
|---|---|
| `143566b6` | Blast Radius Report (`docs/blast_radius/W1_DISTILL_BLAST_RADIUS.md`) |
| `df4b77b7` | Part 1 — §4 schema columns, storage plumbing, NULL-on-edit + erasure scrub, row-crypto `distilled` protection (both legs, SQLite + Postgres) |
| `ef620172` | Part 2 — §5 Stage-5 rendering, §7.6 TokenCompaction, §6 estimator, `[DIST\|]`/DistilledHeader retirement, §13.9 golden vectors |
| `c63f4d9a` | Part 3 — §7 generation paths, §8 lane re-key to source drawer id, §7.1 drain-stage rider (onEncoded-before-reply), §9 geometry probe |
| `2ef51ecf` | Part 4a — §10.1 HydrationRepresentation, Distill recipe, DistilledRecall v2, Recollect retirement, expunge distillation-lane scrub |
| `baf29a90` | Part 4b — MCP surface: `moot_distill` + unlisted alias, `moot_recall_distilled` v2, `moot_recollect` removed |
| `6061e85d` | Part 4c — drain accounting (`distillation` DrainStatus + countUndistilled both legs), VaultKit `_distilled_from` import-reconstruction retirement |
| `e1ab84ba` | Part 4d — installer `.ask` classification both legs (alias exemption), ARIA_MCP_SPEC.md roster |
| `834e16e9` | Part 4e — Adams post-flight comment-fidelity fixes + BRR reclassifications + this report |
| (HEAD) | Part 4f — Finding 3 fix (PERF_W1_DRAIN_RIDER_2026-07-28): T5 finisher gate keys on the encode drain only — `DrainStatus.encodeSettled` / `DrainStatus::encode_settled` both legs, wired into ServeCommand T5 spawn, DrainCommand poll loop, and Rust drain.rs poll loop, + regression tests both legs (GLK Swift 641, GLK Rust t5_encode_settled_parity 4/4) |

## Test Verification Log (final full runs, real exit codes)

Swift (`swift test`, exit 0 each): SubstrateML 508 (baseline 487) ·
LocusKit 845+8 (836+8) · PersistenceKit 506 (499) · CorpusKit 396 (396)
· NeuronKit 531 (531) · GeniusLocusKit 637 (628) · CognitionKit 222
(230; net −8 from retired Recollect/DIST-header suites, replaced by
on-row-contract suites) · AriaMcpKit 23+536 (23+554; retired
InjectionDepth/recollect suites) · VaultKit 192 (192) ·
MootInstallerCore PermissionsWriterTests 19.

Rust (`cargo test`, exit 0 each, zero FAILED): substrate_ml (317 lib +
22 conformance incl. 4 new golden vectors), locus_kit (736 lib),
persistence_kit (179 lib), corpus_kit, neuron_kit, genius_locus_kit,
cognition_kit (181 lib), aria_mcp_kit (dispatch 232), vault_kit,
mootx01 (permissions 14).

Twin conformance: §13.9 golden vectors pinned byte-exact in
TokenCompactionConformanceTests ⇄ token_compaction_conformance.rs (the
§5.4 example sources) plus a byte-exact Stage-5 rendering vector in both
NeuronKit lens conformance suites. The p1 contract pins
`DistillationPipeline.defaultExtractor` on both legs.

## §13 acceptance criteria

1. Population — PASS (drain-stage + sweep cover every active non-empty
   item, including <3-sentence items; GLK DistillationDrainStageTests,
   CK-DI-4/6, Rust CK-DI-R2).
2. Zero factoid drawers — PASS in all new-write paths (CK-INT-4, GLK
   §11 tests, VaultKit no-reconstruction tests, Rust twins).
3. Geometry invariance — PASS (probe test: pre/post-sweep search
   snapshots byte-identical; representation writes enqueue no
   ContentIndexJob).
4. Recall equivalence — PASS (CK-DR-2 / CK-DR-R2: ids and order
   identical to exact search; strictly smaller payloads on distilled
   rows; per-hit token counts).
5. Token counts — PASS (estimator bit-identical Swift/Rust; stored on
   every distilled row; ±20% target asserted by the documented
   (3B+16W+12)/24 blend — no live cl100k comparison run, no vendor
   tokenizer exists in-repo).
6. Regeneration — PASS (NULL-on-edit in the same statement at every
   content-writing site; stale-version resweep replaces the rendering
   and the lane entry; CK-INT-3).
7. Tool surface — PASS (`moot_distill` listed and functional; alias
   identical-handler proven on both legs).
8. Migration round-trip — DEFERRED BY DESIGN: Appendix A is a separate
   later mission per orders. The 2026-07-28 correction to Appendix A
   step (a) affects only that mission.
9. Format conformance — PASS (golden vectors byte-identical both legs).

## Design decisions (flagged for review)

1. **No separate distillation queue/worker.** §7.1's barrier is
   delivered by the encode-drain rider (onEncoded fires BEFORE the
   terminal queue reply, so encode jobs stay in-flight until their
   drawers are distilled — test-proven), plus a `distillation`
   DrainStatus whose `pending` is the §7.1 eligibility-predicate row
   count on both legs. This is FINDING_11X_MAINTENANCE_WALK's own Q2
   option 1; Adams judged it within spec discretion. A literal stream +
   worker remains a bounded follow-up if wanted.
2. **"p1" pins the default extractor** for all production distillation
   writes (§5.3 rule 6 forces one extractor across legs; also makes
   stored fingerprints self-consistent with queryFingerprint).
3. **§7.4 "tail compresses hardest"** is realized by core-first
   ordering under the single §7.6 transform (rule 1 forbids a lossier
   tail transform).
4. **`moot_recollect` retirement** is spec-silent but forced: its
   entire substrate is retired by §11; hits ARE source drawers.
5. **Row-crypto UPDATE seam** now encrypts protected text on update
   (was refuse-only); one PersistenceKit test rewritten to the stronger
   encrypt-on-update contract.
6. VaultKit **export**-side `distilled_from_sources` serialization left
   in place (reads tunnels that cannot exist on 1.1.x; import ignores
   the key) — cleanup candidate.
7. Pre-existing divergence observed, not fixed (out of scope): the
   Rust expunge gate-reject branch does not scrub sibling content the
   way Swift does.
8. **T5 finisher gate is encode-only** (Finding 3,
   PERF_W1_DRAIN_RIDER_2026-07-28): `DrainStatus.encodeSettled` /
   `encode_settled` ignores every drain except `corpus_encode`, because
   the distillation entry counts system-provisioned drawers (wing
   seeds, AI_Charter_Hint) that never transit the encode queue and can
   only be distilled by a sweep — a finisher keyed on all drains would
   hold the encode DrainLease to its full max wait. Two open questions
   flagged, NOT implemented here: (a) whether `countUndistilled` should
   exclude system-provisioned drawers — belongs to the bitmap rider
   design (an operational-bitmap bit is the right discriminator; a
   provenance/actor-string heuristic would be a schema smell); (b) the
   mcp-benchmarker EncodeBarrier settles on all-lanes-idle from tool
   text and would wait out its grace window on a 1.1.x estate whose
   system drawers were never swept — it holds no lease, so this is a
   benchmarker-methodology question, not a product bug.

## Notes

- `EmbeddedArtifacts.swift` / `install-bundle.json` are generated by
  `tools/moot-packager`, which lives in the EE repo (the EE→CE sync
  gate overwrites this tree). The stale embedded skill text was updated
  by exact textual substitution of the changed SKILL.md lines (12
  occurrences per file, JSON validity + Swift build verified); the EE
  packager run will reconcile on the next sync.
- mcp-benchmarker required no code change: the dense arm calls the
  still-accepted alias and the payload parsers
  (lmeParseResultCount/discrimination) are compatible with the new
  `found N memory(s) [distilled]` header.
- RecallDirector query-side wiring of the fingerprint lane: untouched
  per scope order (separate stream).
- RESCOPE_REQUIRED: none.
