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

## Scale qualification (P6)

Fixture: online-backup clone of the production estate that exposed the
7.7 GB growth. 110,451 legacy chunks; 98,118 drawers; 1,139,507 vector
rows (1,094,459 chunk-keyed corpus rows across the five-signal ensemble;
45,048 drawer-keyed `distillation-features-v1` rows owned by another
lane); 7,381,853 BM25 posting rows; freelist already 177,594 pages.

Pre-migration table footprint (dbstat): vectors 2.21 GB; provider basis
1.52 GB; provider counts 0.87 GB; BM25 postings + indexes 1.22 GB;
drawers 0.115 GB; chunks (copy lane) 0.101 GB.

### Measured outcome — Rust leg, single uninterrupted run

| Metric | Value |
|--------|-------|
| End-to-end migration (all 9 states) | 46.3 min |
| Legacy chunks retired | 110,451 |
| Exact vector keys deleted | 1,094,459 |
| Drawers rebuilt + attested | 98,118 / 98,118 |
| Rebuild throughput (incl. all phases) | 35.4 drawers/s |
| Peak resident memory | 5.82 GB |
| Physical reclaim duration | 4.4 s |
| Database file before → after | 7,285,350,400 → 1,261,109,248 B |
| WAL before → after | 638,657,712 → 0 B |
| **Filesystem bytes released** | **6,662,898,864 (−83%)** |
| Freelist pages before → after | 1,449,683 → 0 |
| Drawer-keyed vector partition after | exactly 2 × 98,118 rows |
| Unrelated lane rows after | 45,048 / 45,048, byte-identical |
| BM25 recall latency (warm) | 0.2–0.3 ms top-5 |
| BM25 first query (in-memory index build) | 2.6 s |
| Top-hit direct Drawer hydration | 3/3 queries |

### Measured outcome — Swift leg, single uninterrupted run

| Metric | Value |
|--------|-------|
| End-to-end migration (all 9 states) | 46.0 min |
| Legacy chunks / vector keys retired | 110,451 / 1,094,459 (identical to Rust) |
| Drawers rebuilt + attested | 98,118 / 98,118 |
| Rebuild throughput (incl. all phases) | 35.6 drawers/s |
| Estimate recorded at reclaimPending | 5,937,987,584 B |
| Physical reclaim duration | 4.9 s |
| Database file after | 1,261,096,960 B |
| Filesystem bytes released (file+WAL) | 7,177,536,232 (WAL had grown to 1.15 GB during the run) |
| Freelist pages after | 0 |
| BM25 recall latency (warm) | 0.6–0.9 ms top-5 |
| Top-hit direct Drawer hydration | 3/3 queries |

**Cross-port parity at scale:** the two legs migrated independent clones
of the same estate and produced identical inventory counts, identical
indexed/attested counts, and BYTE-EQUAL BM25 top scores on all three
qualification queries (1402 / 1735 / 1563) — direct evidence the two
ports compute the same recall over 98k drawers.

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

### Flow coverage

| Flow | Evidence |
|------|----------|
| Fresh install | fresh-bypass suites (P4): no record, no legacy tables ever created |
| Standalone CorpusKit | engine standalone suites (P1/P2): put/index/recall + passage chunking standalone-only |
| GLK attached | cutover suites (P3) + this qualification's post-migration recall |
| Interrupted migration | two real kills + resume (above); per-state fault injection both ports |
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
