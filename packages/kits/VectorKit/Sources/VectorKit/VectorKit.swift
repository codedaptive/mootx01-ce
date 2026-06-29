// VectorKit.swift
//
// VectorKit provides on-device embedding generation and model-tagged
// vector storage. Its public surface includes:
//   - `EmbeddingProvider` protocol — the embedding seam (any provider
//     conforms to it; FloatSimHashEmbeddingProvider ships in this kit)
//   - `VectorStore` — typed payload storage backed by ResidentArrayStore
//     with sidecar-backed resident-array persistence (.vec files)
//   - `BruteForceIndex` / `MIHIndex` — exact nearest-neighbour search
//     over the resident array
//   - `ResidentArrayStore` — sidecar-backed mmap array for the index
//
// Per spec I-4, every stored vector is tagged with the model ID and
// version that produced it — cross-model comparisons are forbidden
// because Hamming distance is only meaningful within a fixed model.
//
// Per spec I-12, VectorKit composes onto the substrate kit stack via
// EngramLib's `Engram` type as the canonical 256-bit vector
// representation. VectorKit does not see substrate kernel selection.
//
// Consumers `import EngramLib` to use the `Engram` type alongside
// VectorKit. This kit does not re-export it — keeping the import
// surface explicit matches the rest of the substrate kit stack.

import Foundation
