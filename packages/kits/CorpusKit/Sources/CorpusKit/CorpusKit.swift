// CorpusKit.swift
//
// Module doc. CorpusKit is the RAG layer of the GeniusLocus substrate.
// It depends on VectorKit (vector primitives), PersistenceKit (content
// and bundle persistence), ConvergenceKit (replication of content +
// vectors across devices), EngramLib (typed Engram), and
// SubstrateLib (HLC, fingerprints).
//
// The kit ships in two targets:
//   CorpusKit -- tokenizer protocol, chunker, BM25 inverted index,
//             bundle storage, sync manifest. No model weights, no
//             CoreML, no network.
//   CorpusKitProviders -- three text embedding providers (MiniLM,
//             mpnet, EmbeddingGemma) and their tokenizers. CoreML
//             models live in the host app's bundle; providers
//             resolve them at runtime.
//
// Per the kit graph (mission 7), tokenization lives in CorpusKit, not
// VectorKit. VectorKit ships only the low-level
// FloatSimHashEmbeddingProvider (host-supplied inference + canonical
// projection); the model-specific text providers with tokenizers and
// projection seeds live here in CorpusKitProviders.

import Foundation
