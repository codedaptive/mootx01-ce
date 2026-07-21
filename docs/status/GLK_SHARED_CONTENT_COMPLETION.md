---
title: GLK Shared-Content 1.1 Completion Report
mission: GLK_SHARED_CONTENT (P0–P6)
status: COMPLETE
date: 2026-07-21
---

# COMPLETION: GLK shared-content 1.1

One content row per Drawer. LocusKit owns canonical content; GLK owns
composition through the `CorpusContentSource` adapter; CorpusKit owns only
rebuildable derived state in attached mode. No chunk identity lane, no
chunk-to-Drawer translation, no copied text. Both ports, per-phase parity.

## Phase ledger

| Phase | Delivered | Both ports |
|-------|-----------|------------|
| P0 | Layout signatures, deterministic table inventories, exact-key vector mutation + representation claims, characterization baselines | ✓ |
| P1 | Canonical content boundary: `CorpusContentSource`/Store, operating profiles, attached-mode gate (`.wholeContent` mandatory, passages standalone-only) | ✓ |
| P2 | Canonical-ID engine: ID-keyed derived rows, stale-revision gate, byte-idempotent replay, ingest queue carrying id/revision/digest/cursor only | ✓ |
| P3 | GLK attached composition cutover: adapter-wired engine, drawer-ID identity across BM25/vector/signals/Merkle attestations | ✓ |
| P4 | Resumable fail-dark 9-state migration, structural detection, selective deletion, declared-migration schema retirement, dark-lane gate; Rust SQLite declared-migration execution parity fix | ✓ |
| P5 | Storage maintenance API (checkpoint+VACUUM with quiescence/capacity/progress/cancellation/introspection contracts), ownership-scoped legacy teardown, reclaim wiring + status surface; P3 consumer cutover completed for AriaMcpKit/VaultKit Rust | ✓ |
| P6 | Scale qualification on a 7.3 GB production estate clone + three in-cycle corrections (below) | ✓ |
| Corrective pass | Full five-signal ensemble on migrated estates: per-provider coverage checkpoints, bounded crash-safe training with atomic basis+counts commits, coverage-driven backfill, ensemble fingerprint + follow-on upgrade, claim-aware shared-vector deletion, attached binary lanes default-slot-only, counts write-amplification removed | ✓ |

## Scale qualification (P6)

Fixture: online-backup clone of the production estate that exposed the
7.7 GB growth. 110,451 legacy chunks; 98,118 drawers; 1,139,507 vector
rows (1,094,459 chunk-keyed corpus rows across the five-signal ensemble;
45,048 drawer-keyed `distillation-features-v1` rows owned by another
lane); 7,381,853 BM25 posting rows; freelist already 177,594 pages.

Pre-migration table footprint (dbstat): vectors 2.21 GB; provider basis
1.52 GB; provider counts 0.87 GB; BM25 postings + indexes 1.22 GB;
drawers 0.115 GB; chunks (copy lane) 0.101 GB.

### Measured outcome — five-signal qualification (corrective pass)

The binding qualification is the FIVE-SIGNAL result (RI/PPMI/LSA/NMF/FDC —
the production `defaultEnsemble()`): the migration trains all four
trainable providers on the estate's own content and finishes only when
every provider covers every Drawer. The earlier deterministic-only tables
remain below for history; they qualified an intermediate that the
corrective pass retired.

#### Rust leg (single uninterrupted run)

| Metric | Value |
|--------|-------|
| End-to-end migration (all 11 states) | 39.3 min |
| Legacy chunks / exact vector keys retired | 110,451 / 1,094,459 |
| Drawers rebuilt + attested | 98,118 / 98,118 |
| Structural rebuild throughput | ~72 drawers/s |
| Whole-run throughput (incl. training + backfill) | 41.6 drawers/s |
| Peak resident memory (training phase) | 26.9 GB |
| Physical reclaim | 3.00 GB in 16.2 s (freelist 350,030 → 0, WAL 1.47 GB → 0) |
| Database file after reclaim | 5,753,581,568 B |
| Whole estate directory after | 5,780,317,911 B (db + WAL 70 KB + SHM 11.2 MB + `.vectors.vec` 15.4 MB; queue db absent in the driver run) |
| Per-provider coverage | 98,118/98,118 × 5 providers, digests recorded |
| Vector rows | 632,840 total — RI lane0 (binary) 98,118 (DEFAULT slot only); float lane1: RI 98,069, PPMI 98,069, LSA 97,709, NMF 97,709, FDC 98,118; `distillation-features-v1` 45,048 preserved byte-count-exact |
| Float-lane shortfalls | LSA/NMF −409, RI/PPMI −49: drawers whose content embeds to an empty float vector under that provider — covered (processed) but rowless by design |
| Table bytes after (top) | vectors 1.95 GB; provider basis 1.50 GB; provider counts 0.90 GB; BM25 postings+indexes 0.79 GB; drawers 0.11 GB; coverage 0.069 GB |
| Per-signal float recall | all 5 signals served hits on 3/3 queries (first-call lane build 1.3–1.5 s; BM25 warm 0.2–0.3 ms; first BM25 call 2.1 s) |
| BM25 top scores | 1402 / 1735 / 1563 — byte-equal to every prior run |
| Direct Drawer hydration | 3/3 queries |

#### Swift leg (single uninterrupted run)

| Metric | Value |
|--------|-------|
| End-to-end migration (all 11 states) | SWIFT5_MIGRATION_MIN |
| Drawers rebuilt + attested | SWIFT5_REBUILT |
| Per-provider coverage | SWIFT5_COVERAGE |
| Per-signal float recall | SWIFT5_FLOAT |
| BM25 top scores | SWIFT5_SCORES |
| Physical reclaim | SWIFT5_RECLAIM |

SWIFT5_PARITY_NOTE

#### Historical: deterministic-only intermediate (superseded)

Rust 46.3 min / Swift 46.0 min; 6.66–7.18 GB reclaimed (the five-signal
steady state legitimately retains ~4.5 GB more: the five vector lanes,
the trained bases, and the training-corpus counts); byte-equal BM25 top
scores across ports; peak RSS 5.8 GB. Those runs validated retirement,
resume, reclamation, and identity — but left the four trainable signals
dark, which the corrective pass fixed.

### Interruption / resume at scale

Two real mid-flight SIGKILLs (one 24 min in, one mid-rebuild at cursor
2,000) resumed from the persisted record and cursor checkpoint with no
restart and no corruption; the per-state fault-injection suites cover the
remaining seams in both ports.

### Corrections the qualification surfaced (fixed in-cycle, both ports)

1. **Rebuild deferred-index window** — per-Drawer resident-index rebuild
   made the rebuild quadratic (17/s decaying to 8/s by 3k drawers);
   wrapping the rebuild in the VectorStore deferred window restored flat
   ~35–50 drawers/s over all 98k.
2. **Protected-fold decode pinning** — verification false-positive: the
   baseline and verify folds decoded the vectors table through different
   accumulated schema views. Both now pin the declared VectorKit schema.
   Diagnosis proved the protected rows themselves were byte-identical.
3. **Record hygiene** — the completed record trims its consumed
   inventories (was ~60 MB durable residue), persisting counts; the Rust
   leg now records the reclaim estimate at `reclaimPending` (parity).

### Corrective pass (verified gaps, closed both ports)

1. **Deterministic-only rebuild** — the migration completed with four of
   five signals dark. Fixed: `basesTrained` + `providersCovered` states;
   verification asserts per-provider coverage of every Drawer under the
   recorded basis digest before the lane lights.
2. **Provider-blind checkpoints** — `corpus_index_state` said "indexed"
   with no provider/generation dimension. Fixed: `corpus_provider_coverage`
   rows (content × provider × basis digest), written after the vector
   rows so bookkeeping can lag durable coverage but never lead it.
3. **Unsuitable naïve reindex** — corpus materialization for training,
   per-Drawer counts refolds, full-rewrite semantics. Fixed: streamed
   bounded training (`accumulateTraining`/`finalizeTraining`, atomic
   basis+counts commit per provider) and coverage-driven backfill that
   writes only missing representations; counts persist at batch
   boundaries only.
4. **Claims-blind deletion** — remove/destroy deleted exact keys without
   consulting the ledger. Fixed: a key is deleted only when no other
   retained claimant claims its representation family; proven by the
   shared-ownership suites.
5. Also: attached-mode binary rows/claims are DEFAULT-slot-only (every
   GLK Hamming reader probes the default model; non-default binary rows
   were unreachable weight), and a completed record with an obsolete
   ensemble fingerprint enters a follow-on upgrade (tested by adding a
   provider to a migrated estate).

### Flow coverage

| Flow | Evidence |
|------|----------|
| Fresh install | fresh-bypass suites (P4): no record, no legacy tables ever created |
| Standalone CorpusKit | engine standalone suites (P1/P2): put/index/recall + passage chunking standalone-only |
| GLK attached | cutover suites (P3) + this qualification's post-migration recall |
| Interrupted migration | two real kills + resume (above); per-state fault injection both ports incl. the training/coverage states; crash-boundary suites for train-before/after-commit, backfill after-vectors/after-coverage, lagging and digest-mismatched coverage |
| Ensemble upgrade | provider added to a migrated estate: lane dark on fingerprint mismatch → upgrade trains + backfills only the addition → re-verifies (both ports) |
| Insufficient-disk reclaim | maintenance preflight contract suites (P5): `insufficientDiskCapacity` refused before any rewrite |
| Upgrade/reopen | qualification reopens the migrated estate for the recall phase; restart-idempotent wiring suites (AriaMcpKit) |

### Suite state at completion

Full sweeps green in both ports: PersistenceKit, VectorKit, CorpusKit
(370 Swift / all Rust suites incl. characterization twins), GeniusLocusKit
(631+ Swift / all Rust suites incl. `test-seams`), AriaMcpKit (557 Swift /
all Rust), VaultKit, CognitionKit (230); every Swift package and Rust
crate in the tree builds clean; CE fast unit lane green.

## Release-notes summary

Shared-content 1.1 stores each memory's canonical text exactly once.
Estates carrying the legacy copy lane migrate in place through a
resumable, fail-dark migration during a maintenance window; migration of
a 7.3 GB estate took ~46 minutes and returned 6.7 GB to the filesystem.
Until an estate migrates, its semantic-recall lane stays dark (structural
recall unaffected); recall lights up immediately after migration with
identical hit quality and direct Drawer identity across every lane.
