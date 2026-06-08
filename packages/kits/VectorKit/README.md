# VectorKit

**Status:** Mission 6 refactor complete (2026-05-19): on PersistenceKit + SubstrateLib, three production blockers fixed.
**Standalone:** Yes; use independently, no other kits required.

A Swift library for on-device embedding generation and vector search on Apple Silicon. VectorKit gives any application a privacy-first semantic search layer; generate embeddings locally via CoreML, store them model-tagged, and query by nearest-neighbour; with zero cloud dependency.

## Standalone value

Use VectorKit to build:
- **Semantic search** for any application; find content by meaning, not just keywords
- A **private embedding store**; generate and persist vectors on-device, tagged by model and version
- A **RAG vector tier**; the vector half of retrieval-augmented generation, without bundling content

VectorKit is complete on its own. You do not need LocusKit, CorpusKit, or GeniusLocusKit to use it.

## Mission 6 changes (2026-05-19)

Refactored per `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md` section 4.6.

1. Storage now consumes PersistenceKit's `Storage` protocol. The direct SQLite I/O in `VectorStore` is gone. Callers pass `any Storage` (SQLite, PostgreSQL, or InMemory) and `VectorStore.schemaDeclaration` to `storage.open(schema:)` before constructing the store.

2. The sign-bit float-to-engram projection in `MiniLMProvider` is replaced by `SubstrateLib.FloatSimHash`. Cosine similarity is preserved approximately (Hamming distance proportional to angular distance per cookbook section 3.6). Each provider picks a stable seed so its fingerprints are model-tagged independent of vector content.

3. The Rust crate's inline `uuid_lite` shim is replaced by the real `uuid` crate (v1, features = ["v4"]).

4. WordPiece tokenization stays in `MiniLMProvider` as a deterministic stand-in for now. Per the kit graph, text tokenization moves to CorpusKit in mission 7; after that, MiniLMProvider will consume CorpusKit's tokenizer protocol.

29 Swift tests pass (5 skipped, no model in bundle). 15 Rust tests pass.

## What this kit provides

- **`EmbeddingProvider` protocol**; pluggable model interface; swap models without changing call sites
- **CoreML adapter**; on-device embedding inference (MiniLM v1.0; EmbeddingGemma 300M target)
- **Model+version tagging**; every stored vector carries the model ID and version that produced it; queries filter by model (spec I-4)
- **Vector storage**; SQLite-backed via sqlite-vec; one vector per drawer per model
- **Nearest-neighbour query**; approximate nearest neighbour via HNSW index; Metal-accelerated cosine similarity
- **BM25 index**; keyword scoring alongside vector search for hybrid retrieval
- **Capture-path latency**; P99 under 100 ms on iPhone for embedding + store (spec requirement)

## What this kit does NOT provide

- Structured content, KG facts, or audit → **LocusKit**
- Content-plus-vector RAG bundles → **CorpusKit**
- The unified nine-verb estate surface → **GeniusLocusKit**
- AI reasoning algorithms → **NeuronKit**
- Behaviour recipes → **CognitionKit**
- MCP server → **ARIA_MCP**

## Platform

- **Swift**; Apple Silicon, macOS 15+, iOS 18+
- **Rust**; PC/Linux x86_64, Linux aarch64 (built in parallel; conformance-gated against shared test vectors)
- CoreML for on-device inference
- sqlite-vec for vector storage and HNSW index
- Metal compute for cosine similarity
- Swift 6 strict concurrency

## Build order

VectorKit builds in **parallel with LocusKit** (Phase 1). It has no dependency on LocusKit. CorpusKit gates on VectorKit; build VectorKit first.

## Key specs

- `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`; I-4 (model tagging), I-12 (substrate composition), § 15.1
- `docs/specs/GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md`; § 2, VectorKit done-definition
- `docs/validation/substrate_math_performance/`; `glref-swift-HammingNN.swift`, `glref-swift-SimHash.swift`, `glref-swift-HyperplaneFamily.swift`

## Scope

**Belongs here** if it touches: `EmbeddingProvider` protocol, CoreML adapters, vector storage schema, HNSW index, BM25 index, nearest-neighbour query, Metal cosine kernels, model+version tagging.

**Does not belong here** if it: stores structured content → LocusKit · bundles content+vector → CorpusKit · implements reasoning → NeuronKit · exposes MCP → ARIA_MCP.
