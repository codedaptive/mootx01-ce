import EngramLib
import Foundation

/// Protocol for on-device embedding generation.
///
/// Conforming types take text and return an `Engram` tagged with the
/// model identity that produced it. Per spec I-4 every stored vector
/// carries the model ID and version — cross-model comparisons are
/// forbidden, so the provider's `modelID` and `modelVersion` are part
/// of the storage record, not just the inference call.
///
/// Implementations are expected to be `Sendable` because embedding
/// jobs run on background tasks (capture path P99 < 100 ms per the
/// VectorKit spec) and providers are typically shared across actors.
public protocol EmbeddingProvider: Sendable {
    /// Stable identifier for this model (e.g. `"minilm-v6"`). Used
    /// to tag stored vectors and to filter queries to a single model.
    var modelID: String { get }

    /// Semantic version of the model weights (e.g. `"1.0.0"`). A
    /// weight update bumps this string; vectors produced under
    /// different versions cannot be compared.
    var modelVersion: String { get }

    /// Generate an engram for the given text.
    ///
    /// - Parameter text: Input text. Empty input is permitted.
    ///   Conformers MUST return the substrate's canonical zero
    ///   engram (`Engram.zero`) for the empty string. This is the
    ///   cross-provider contract: every `EmbeddingProvider` in the
    ///   kit graph treats the empty string identically, so empty
    ///   rows from different providers collide on the same
    ///   Hamming-distance-0 partition. The Rust `EmbeddingProvider`
    ///   trait carries the identical rule.
    /// - Throws: `VectorKitError.embeddingFailed` on inference failure,
    ///   `VectorKitError.modelUnavailable` if the model is not loaded.
    func embed(_ text: String) async throws -> Engram

    /// Generate the pooled dense float vector for the given text — the
    /// float lane's source (Lane D).
    ///
    /// This is the SAME vector the provider's `embed(_:)` already computes
    /// on the way to the SimHash projection. Providers that run a real
    /// inference pass (MiniLM, mpnet, EmbeddingGemma) override this to
    /// return the pooled vector they would otherwise discard inside
    /// `FloatSimHash.project(...)` — the two outputs come from one
    /// inference pass, so no model is loaded twice and no extra projection
    /// runs. The returned vector is host-endian `[Float]`; the storage
    /// layer serialises it to IEEE-754 little-endian via
    /// `VectorPayload(floats:)`.
    ///
    /// - Parameter text: Input text. Empty input returns an empty array
    ///   (`[]`): there is no dense direction for the empty string, and the
    ///   binary lane already collapses empty input to `Engram.zero`. A
    ///   float lane that returned a zero-filled vector here would surface
    ///   every empty row as a cosine-distance-1 spurious neighbour.
    /// - Returns: the pooled float embedding, or `[]` for empty input.
    /// - Throws: `VectorKitError.embeddingFailed` by default — float
    ///   embeddings are opt-in. Providers that do not produce a dense
    ///   float vector (the default implementation below) throw so callers
    ///   must handle the unsupported case explicitly rather than receiving
    ///   a silently-wrong projection of the binary fingerprint. The Rust
    ///   `EmbeddingProvider` trait carries the identical opt-out rule.
    func embedFloat(_ text: String) async throws -> [Float]

    /// Generate the binary engram AND the dense float vector for `text` from a
    /// SINGLE inference pass.
    ///
    /// `embed(_:)` already computes the pooled float vector on its way to the
    /// SimHash projection, and `embedFloat(_:)` computes that same vector — so a
    /// caller that needs both (the Corpus ingest float lane) would otherwise run
    /// the provider's inference twice per chunk. Providers that compute-then-
    /// project SHOULD override this to run the inference ONCE and return both
    /// outputs; the default implementation below preserves the historical two-
    /// pass behaviour for providers that have not been migrated.
    ///
    /// - Returns: `(engram, floats)`. `floats` is `[]` when the provider opts
    ///   out of the float lane (binary-only providers) or for empty/unresolved
    ///   input — identical to the `embedFloat(_:)` opt-out contract. The Rust
    ///   `EmbeddingProvider` trait carries the identical `embed_pair` rule.
    func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float])

    /// Generate engrams for a batch of texts.
    ///
    /// The default implementation (below) calls `embed` sequentially;
    /// providers with batched CoreML graphs or other batch-aware
    /// inference paths SHOULD override for throughput. Order of
    /// outputs MUST match the order of inputs.
    ///
    /// An empty input array returns an empty result. Each empty
    /// string in the input array yields `Engram.zero` per the
    /// `embed` contract above.
    func embedBatch(_ texts: [String]) async throws -> [Engram]
}

public extension EmbeddingProvider {
    /// Default opt-out for the float lane: a provider that does not
    /// produce a dense float vector throws `embeddingFailed`. Float
    /// embeddings are opt-in — only providers that override this method
    /// (returning the pooled vector from their inference pass) support
    /// the float lane. Throwing rather than synthesising a vector keeps
    /// the contract explicit: a caller that asks for `embedFloat` on an
    /// unsupporting provider learns so immediately instead of recalling
    /// against meaningless coordinates.
    func embedFloat(_ text: String) async throws -> [Float] {
        throw VectorKitError.embeddingFailed(
            "embedFloat is not supported by this provider (modelID=\(modelID)); the float lane is opt-in")
    }

    /// Default `embedPair`: two inference passes (`embed` then `embedFloat`),
    /// preserving the historical behaviour for providers that have not been
    /// migrated to single-pass. The float-lane opt-out (a throwing `embedFloat`)
    /// is swallowed to `[]`, matching the ingest call site's `try?` contract, so
    /// this default is behaviour-identical to the pre-migration two-call code.
    func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let engram = try await embed(text)
        let floats = (try? await embedFloat(text)) ?? []
        return (engram, floats)
    }

    /// Default sequential implementation of `embedBatch`. Providers
    /// with batched inference paths should override.
    func embedBatch(_ texts: [String]) async throws -> [Engram] {
        var out: [Engram] = []
        out.reserveCapacity(texts.count)
        for t in texts {
            out.append(try await embed(t))
        }
        return out
    }
}
