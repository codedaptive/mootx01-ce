# vectorkit (Rust)

Rust port of the Swift `VectorKit` Swift Package. On-device embedding generation, model-tagged vector storage, and Hamming-distance nearest-neighbour retrieval.

**Status:** v0.2.0 — refactored 2026-05-19 (Rust mission 6) per `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#21-dependency-direction-and-kit-ownership` section 4.6.

## What changed in v0.2.0

- **Storage moved off direct rusqlite onto `storage-kit`.** `VectorStore` now consumes `Arc<dyn Storage>`; the application picks the backend (InMemory today, SQLite + PostgreSQL when those backends land in storage-kit follow-on R-missions).
- **`FloatSimHashEmbeddingProvider` added** alongside the existing `MockEmbeddingProvider` and `ScalarEmbeddingProvider` stubs. Mirrors Swift's MiniLM / mpnet / EmbeddingGemma providers in CorpusKit: closure-injected inference, stable per-provider FloatSimHash seed (`0x4D49_4E4C_4D_5F76_31` for MiniLM, `0x4D50_4E45_54_5F76_31` for mpnet, `0x454D_4247_4D_5F76_31` for EmbeddingGemma).
- **FTS5 removed.** `find_by_keyword` is now a substring `LIKE` on `drawer_id`; full BM25 lives in CorpusKit per the kit graph.
- **`filed_at` is now `i64` Unix epoch seconds**, matching storage-kit's `TypedValue::Timestamp(i64)`. The Swift side made the same change.
- **`find_nearest` is still a linear Hamming scan.** ANN via `storage_kit::VectorIndex` is a follow-on; the public API does not change when that lands.

## API surface

- `EmbeddingProvider` trait (unchanged): `model_id()`, `model_version()`, `embed(&str) -> Result<Engram, VectorKitError>`
- `MockEmbeddingProvider` — deterministic FNV stub for tests
- `ScalarEmbeddingProvider` — pure-Rust FNV stub for Linux builds
- `FloatSimHashEmbeddingProvider` — closure-injected inference + FloatSimHash projection; `::minilm`, `::mpnet`, `::embedding_gemma` convenience constructors with Swift-matching seeds
- `VectorStore` — storage-kit-backed CRUD; methods unchanged: `add_vector`, `get_vector`, `vectors_for_drawer`, `find_nearest`, `find_by_keyword`, `delete_vector`. `schema_declaration()` is a public static for callers that want to call `storage.open(&schema)` themselves.

## Tests

33 integration tests:

- `mock_provider_tests.rs` (4): determinism, distinct seeds, empty input, model identity
- `scalar_provider_tests.rs` (4): same shape as mock, distinct seed space
- `embedding_provider_tests.rs` (4): trait conformance, Send + Sync
- `simhash_provider_tests.rs` (6, new): model identity carries through, embed deterministic for same text, different providers produce different engrams, EmbeddingGemma seed distinct from MiniLM, inference failure surfaces as `VectorKitError::EmbeddingFailed`, empty text produces a stable non-zero engram
- `vector_store_tests.rs` (15): add+get roundtrip, get returns None for unknown, multi-model storage for same drawer, ordering by `filed_at`, delete, model+version roundtrip, upsert on conflict, empty store, `find_nearest` k-results sorted, find_nearest with k > corpus, find_nearest on empty store, find_nearest index maps to correct drawers, `find_by_keyword` matching, find_by_keyword empty for no match, hybrid find_nearest + find_by_keyword overlap

## What does NOT ship at v0.2.0

- ANN over `storage_kit::VectorIndex` (linear Hamming scan continues for now)
- Full BM25 keyword retrieval (deferred to CorpusKit per the kit graph)
- Real ONNX/Candle inference bundles for the FloatSimHash providers (closure-injected; bundles land in a follow-on R-mission)

## Building

```
cd VectorKit/rust
cargo build
cargo test
```

Requires Rust 1.75+ and sibling `substrate-kit`, `engram-kit`, `storage-kit` crates.

## See also

- Swift counterpart: `VectorKit/Sources/`
- Kit graph rule: `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#21-dependency-direction-and-kit-ownership`
