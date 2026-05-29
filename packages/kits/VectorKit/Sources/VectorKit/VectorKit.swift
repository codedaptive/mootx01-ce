// VectorKit.swift
//
// Module doc. VectorKit provides on-device embedding generation and
// model-tagged vector storage. The kit's foundational abstraction is
// the `EmbeddingProvider` protocol (this scaffold, VEC-01); concrete
// adapters (MiniLM in VEC-03 and future models) conform to it.
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
