# Changelog

All notable code changes to MOOTx01 are recorded here. Versions follow
`VERSIONING.md`: semantic `MAJOR.MINOR.PATCH`, pre-release builds tagged with a
qualifier (`v1.0.1-beta`). The version constant tracks the semantic version;
the tag carries the pre-release qualifier.

## v1.0.1-beta — 2026-06-17

Second beta of the 1.0 line. 60 changes since `v1.0.0-beta` (37 features, 7
fixes, 1 performance, 1 refactor, 4 test-hardenings, 4 spec/doc updates, 6
README/ABOUT touch-ups). The headline is the honest-fusion semantic recall
stack and the substrate/kit hardening sweep; both the Swift and Rust ports
move together, conformance-gated.

### Recall — honest classical-fusion semantic recall

- **Decision recorded** — ADR-010: honest classical-fusion semantic recall +
  ARIA recall steering (Decision D); addendum for Decision B (full fusion incl.
  LSA/SVD) and CoreML-encoder flip-the-switch readiness for 1.1.
- **Substrate primitive** — float-vector ops (l2Norm / l2Normalize / dot /
  cosine), Swift+Rust conformance-gated.
- **Distributional embedding providers** (ADR-010 signals, Swift+Rust):
  Random Indexing, PPMI (+ consolidated keyword tokenizer), LSA, NMF-retrieval
  (+ shared term-document builder).
- **Deterministic one-sided Jacobi SVD**, Swift+Rust bit-identical (backs LSA).
- **FDC lane** — `FDC.ancestors(of:)` / `Fdc::ancestors` runtime façade;
  FDCProvider wired to `LatticeLib.FDC.ancestors`; FDC enum wiring + conformance
  fixtures completed.
- **Basis lifecycle** — versioned cross-port basis serialization (RI/PPMI/LSA/
  NMF); `TrainableEmbeddingBasis` seam; basis-persistence table + corpus
  training lifecycle.
- **Corpus N-provider** capability + per-signal nearest-neighbour.
- **Fusion engine** — dense-lane per-signal fan-out + N-way RRF consensus;
  `RecallShape` signed-weight fusion engine wired into the unionBest lane.
- **Steering** — named `RecallShape` preset roster + `ShapedRecall` recipe +
  ARIA exposure; the five matrix/graph/preference columns made RecallShape-
  steerable; anti-similarity (farthest-K) across VectorKit + CorpusKit + GLK.
- **Production default flipped** to the five-signal honest ensemble.
- **Capture/import → encode pipeline** wired across all paths + reindex
  backfill.
- **GLK parity** — GraphCache/PreferenceStore recall surface ported to Rust GLK
  (closes ADR-011 D-4); matrix/graph/preference recall lanes wired into
  RecallDirector.
- **CognitionKit** — `recall_exploratory` recipe consuming
  `RandomWalks.walkWithRestart`.

### Brain layer

- Graph-centrality producer (both ports).
- Bradley-Terry preference producer (both ports).
- Rust autonomic governor owns + ticks the standing-signal scheduler.

### Knowledge / taxonomy

- `DrawerFingerprint.qidClosureHash` wired via a pinned Wikidata Q-ID
  taxonomic-closure artifact (both ports).
- HMM novel-token tagger trained on MASC 3.0.0 (CC BY 3.0 US), rare-word
  (hapax) estimated and frozen as a checked-in resource read bit-identically by
  both ports (A-15).

### Substrate & kit hardening (the audit sweep)

- §11.5 — compile-enforced container-fingerprint **add-coverage** so recall
  pruning can never silently go unsound.
- `AssociationRuleMining` mines k>2 itemsets via Apriori row-replay (SubstrateML).
- `SqliteDrawerStore` gains a cache-accepting constructor; moot-mgr wires it.
- Audit `reason` field persisted through the full audit stack (A-8).
- KGFact exposes all four adjective axes, Rust parity (A-6).
- `CaptureFrame` exposes confirmation + confidence provenance to production
  callers (A-13); propose verb wires its three provenance bitmap axes (A-3).
- `#4` — compile-enforce required trait reads; `#7` Q-ID closure rescoped.
- Schema `ext` forward-compat slot extended to the 5 remaining entity tables
  (ADR-012).
- `ext`/forward-compat groundwork; LocusKit interface bumped to 1.6.0.

### Performance

- `tombstoned_rows_without_expunge_audit` uses a SQL LEFT JOIN in the SQL
  backends instead of an N+1 scan (A-7).

### Refactor

- FdcProvider seeds from the substrate `FNV.hash64` primitive rather than an
  inlined FNV-1a loop (one dense-math library to maintain).

### App / moot-mgr

- Persist a custom retention window to StatsStore across restart (A-10).
- `lastLoggedID` parses the intentRunLog for the created drawer UUID instead of
  always returning nil (A-4).

### Fixes

- Correct the stale `lookup_vectors` `religion_single_token` expected code (a
  common noun must resolve).
- Land FDC enum wiring + conformance fixtures omitted from an earlier commit.
- Parity-sweep: batch parity-clean items + harden two test-isolation flakes.
- Fix `vault_reconcile` temp-dir collision flake (UUID, not nanos).
- Close the VectorKit Rust SQLite cross-restart conformance gap + fix a stale
  `lib.rs` comment (A-11).
- Fix a stale Rust test comment claiming `CaptureFrame` has no confirmation slot.

### Tests & docs

- Test-isolation hardening: moot-mgr retention sidecar per-test directory;
  BasisPersistence tests serialized under `GlobalTestLock`.
- Doc fidelity: correct the stale `shingleSimilarity` rewire comment (A-5);
  spec/interface version bumps; README/ABOUT touch-ups.

## v1.0.0-beta

Initial public beta of the 1.0 line.
