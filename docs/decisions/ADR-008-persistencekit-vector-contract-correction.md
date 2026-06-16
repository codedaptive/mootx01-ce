---
status: decided
question: Does PersistenceKit's Storage own a per-backend vector k-NN engine, or only a storage-capability guarantee for vector workloads?
authors: MOOTx01 maintainers
date: 2026-06-12
relates_to:
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/PERSISTENCEKIT_INTERFACE.md
  - docs/reference/VECTORKIT_SPEC.md
  - docs/decisions/DECISION_STORAGEKIT_DESIGN_2026-05-19.md
supersedes: none
context:
  - The prior storage spec said "Storage surfaces a VectorIndex", implemented as a per-backend k-NN engine (sqlite-vec, pgvector, an InMemory brute-force mirror).
  - The current doctrine removes sqlite-vec; vector engines are in-house and live solely in VectorKit.
  - The fate of the Storage.vectorIndex public contract was previously undecided, blocking the removal.
---

# ADR-008 — PersistenceKit Vector Contract Correction

**Scope:** PersistenceKit (Storage/StorageTransaction protocols, SQLite/PostgreSQL/InMemory backends, conformance harness), VectorKit (NativeANNIndex shell), both ports (Swift + Rust)

## Summary

The prior storage contract carried a per-backend vector-search engine on
`Storage` (`var vectorIndex: any VectorIndex`), realised as `SQLiteVectorIndex`
(sqlite-vec), `PostgreSQLVectorIndex` (pgvector), and `InMemoryVectorIndex`.
This ADR records the correction: that wording was a defect. The INTENT was a
STORAGE-CAPABILITY guarantee — that every backend can accommodate a vector
database's storage needs — not that PersistenceKit owns a k-NN engine. The
engine seam is removed; the guarantee is restated as an accommodation contract
and made permanently machine-enforced by the conformance harness.

## Context — the intended guarantee

The earlier wording "Storage surfaces a VectorIndex" was a wording defect. The
INTENT was: SQLite, Postgres, and InMemory need to be able to accommodate a
vector database's storage needs — a STORAGE-CAPABILITY guarantee, not a
per-backend k-NN engine.

Three candidates were considered: (A) excise the vector surface from
PersistenceKit entirely; (B) give SQLite a resident in-memory VectorIndex; or
(C) make SQLite's vector ops throw `unsupported`. Option A is chosen: post
correction, vectors are a VectorKit-only concern and a PersistenceKit
vector-search surface is vestigial.

## The wording defect

`PERSISTENCEKIT_SPEC.md` §1 read: "Storage surfaces five sub-stores: a
RowStore … a VectorIndex (k-NN search) …" and §5 B-9 specified
`knn(query:k:metric:filter:searchParameters:)` with `DistanceMetric`,
`IndexParameters`, `SearchParameters`, and `VectorSearchResult`. Read
literally, that makes every storage backend a vector-search engine. The
substrate's actual architecture puts dense-embedding k-NN in VectorKit
(HNSW / MIH / brute-force resident indexes); the PersistenceKit "VectorIndex"
was a second, redundant search surface whose only production realisations were
the third-party extensions (sqlite-vec, pgvector) the current doctrine removes.

## The engine-seam supersession

Removed (no bridges, shims, or deprecation stubs):

- `VectorIndex` protocol + `DistanceMetric` / `IndexParameters` /
  `SearchParameters` / `VectorSearchResult` (Swift + Rust).
- The `vectorIndex` requirement on `Storage` and `StorageTransaction`.
- `SQLiteVectorIndex` and the vendored `CSQLiteVec` target / `sqlite-vec.c`
  (Swift) and the `sqlite-vec` crate dependency + auto-extension registration
  (Rust); the `_storagekit_vector_meta` / vec0 schema.
- `PostgreSQLVectorIndex` (pgvector path).
- `InMemoryVectorIndex` and the InMemory `vectors` store.
- `StorageStats.vectorCount` (+ the `persistence.db.vector_count` telemetry
  metric) — orphaned by the InMemory vector store's removal.
- VectorKit's `NativeANNIndex` delegate shell + the `.nativeANN` IndexKind
  case (Swift + Rust): its only purpose was forwarding to the removed
  PersistenceKit engines. VectorKit now owns its float-lane metric type
  (`FloatMetric` in both ports), formerly aliased to
  `PersistenceKit.DistanceMetric`.

## The accommodation contract (replacement)

`Storage` is `RowStore` + `BlobStore` + `AuditLog` + `StorageObserver`. The
restated guarantee (SPEC I-1a, B-9): every backend MUST support vector
workloads' storage needs — vector-payload round-trip (binary 32-byte and
float32 384-d payloads), bulk hydration at scale (≥1,000 vector rows),
count, and delete — through the general RowStore/BlobStore surfaces. The
conformance harness's `vectorFixtures()` / `vector_fixtures` was re-pointed
from per-backend k-NN to these assertions and runs on InMemory, SQLite, and
PostgreSQL in both ports, so the accommodation guarantee stays permanently
machine-enforced.

Vector (dense embedding k-NN) search lives solely in VectorKit. Other search axes — LocusKit's bitmap/lattice/temporal recall, CorpusKit's lexical lanes, SubstrateLib's fingerprint pruning — are unaffected; PersistenceKit backends accommodate the storage needs of all of them without owning any search.

## Why the removal could not be narrow

`VectorIndex`, `InMemoryVectorIndex`, and `PostgreSQLVectorIndex` were NOT
sqlite-vec orphans. Removing only sqlite-vec would have left them with live
consumers: the `Storage.vectorIndex` requirement and the unconditional
`vectorFixtures()` k-NN run against all three backends. Under Option A those
consumers are themselves removed or re-pointed, so the symbols are deleted
together with their consumers — not left orphaned.

That coupling is what forced a public-contract decision. Removing
`SQLiteVectorIndex` (the only sqlite-vec consumer) broke `SQLiteStorage`'s
`Storage.vectorIndex` conformance and the cross-backend k-NN conformance run,
with no bridge or shim permitted. Resolving it required deciding the fate of
the PersistenceKit vector surface itself (candidates A/B/C above), not just the
VectorKit float lane. Option A — excise the surface — is the chosen
resolution, which this ADR records and the implementation executes.

## Disposition

Decided. Option A executed across PersistenceKit + VectorKit, Swift + Rust:
seam removed, contract reworded to the accommodation guarantee, conformance
vector fixtures re-pointed, SPEC + INTERFACE updated. All affected Swift suites
(PersistenceKit, VectorKit, CorpusKit, LocusKit, GeniusLocusKit) and both Rust
twins are green.

## Open questions

None. The accommodation contract is the permanent storage-layer guarantee;
any future on-disk ANN acceleration is a VectorKit decision, not a
PersistenceKit one.
