// TrainableEmbeddingBasis.swift
//
// The seam that lets a type-erased embedding provider be trained on a
// corpus and serialized to (and reconstructed from) a basis blob — without
// the layering inversion that would otherwise be required.
//
// ## Why this protocol lives in CorpusKit core (not VectorKit)
//
// Training-on-corpus is a CorpusKit concern, not a generic embedding
// concern. VectorKit's `EmbeddingProvider` is the universal embed surface;
// it must stay narrow so a future pre-trained CoreML encoder can conform to
// it WITHOUT being forced to declare a training method it cannot honour.
// `TrainableEmbeddingBasis` is the opt-in capability for the distributional
// providers (RI/PPMI/LSA/NMF) that genuinely train on the estate's own
// content. FDC (stateless taxonomic) and the deterministic/named-model
// providers do NOT conform — their opt-out is a clean "does not implement
// this protocol", surfaced to callers as `CorpusKitError.notTrainable`.
//
// ## Why this is the honest dispatch for type erasure
//
// `Corpus` holds the provider as `any EmbeddingProvider` (type-erased), so
// it cannot itself call `train`/`serializeBasis`/`init(deserializing:)` —
// those live on the concrete provider types in CorpusKitProviders, which
// CorpusKit core cannot import (layering runs providers → core). This
// protocol is the bridge: CorpusKit core DECLARES it; CorpusKitProviders
// CONFORMS its concrete providers to it. A type-erased value that conforms
// can be driven through the protocol without core ever naming the concrete
// type. Reconstruction is an INSTANCE method (`reconstructBasis(from:)`)
// because only the concrete value knows how to deserialize into its own
// type — the protocol witness routes the call to the right
// `init(deserializing:)` without core importing the provider module.
//
// Rust port: packages/kits/CorpusKit/rust/src/trainable_embedding_basis.rs
// (the `TrainableEmbeddingBasis` trait).

import Foundation
import VectorKit

/// A provider whose embedding basis is trained from a corpus and can be
/// serialized to / reconstructed from a versioned basis blob.
///
/// Conformers are the CorpusKit distributional providers (RI, PPMI, LSA,
/// NMF) in `CorpusKitProviders`. The protocol is the type-erasure seam that
/// lets `Corpus` (which holds an `any EmbeddingProvider`) drive training and
/// serialization without CorpusKit core importing CorpusKitProviders.
///
/// Class-bound (`AnyObject`): every conformer is a reference-type provider
/// whose training mutates internal state in place, matching the existing
/// `final class` providers.
public protocol TrainableEmbeddingBasis: AnyObject, Sendable {

    /// Train this provider's basis on a corpus of raw document texts.
    ///
    /// The conformer is responsible for the FULL train+finalize sequence
    /// specific to its method:
    ///   - it tokenizes each text with the canonical `defaultKeywordTokens`
    ///     where its training API consumes term sequences (RI, PPMI), or
    ///     passes raw text where its API consumes documents (LSA, NMF);
    ///   - it runs any required finalization pass (PPMI/LSA/NMF; RI has none).
    ///
    /// Deterministic: this method MUST NOT call `Date()`/`now` — training is a
    /// pure function of `texts` and the provider's fixed seeds, so the same
    /// corpus yields a byte-identical basis on every run and on the Rust port.
    ///
    /// Training is additive over multiple calls where the underlying provider
    /// supports it, but the canonical usage is a single call with the whole
    /// corpus followed by serialization.
    ///
    /// - Parameter texts: raw document texts (NOT pre-tokenized term arrays).
    func trainOnCorpus(texts: [String])

    /// Serialize the trained basis to a versioned, little-endian blob.
    ///
    /// This is the same blob the concrete provider's `serializeBasis()`
    /// (mission 6a-i) produces; the protocol merely surfaces it through type
    /// erasure. The byte layout is the cross-port conformance contract: the
    /// Rust conformer's `serialize_basis` yields identical bytes for the same
    /// trained state.
    func serializeBasis() -> Data

    /// Reconstruct a fresh provider of this conformer's concrete type from a
    /// serialized basis blob.
    ///
    /// The returned provider's `embed`/`embedFloat` output is identical to the
    /// originally-trained provider's (round-trip law). Implemented by
    /// delegating to the concrete type's `init(deserializing:)` (mission 6a-i),
    /// so reconstruction routes to the correct concrete type without CorpusKit
    /// core naming it.
    ///
    /// This is an instance method (not a static/initializer) so it can be
    /// invoked on a type-erased witness: `EmbeddingModel.reconstruct(from:)`
    /// calls it on the provider the enum case already carries, which IS the
    /// right concrete type.
    ///
    /// - Parameter basis: the serialized basis blob.
    /// - Returns: a reconstructed provider, type-erased to
    ///   `any EmbeddingProvider & Sendable`.
    /// - Throws: `CorpusKitError.decodingFailure` on a truncated blob, an
    ///   unknown format version, or a provider-magic mismatch — never crashes.
    func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable
}
