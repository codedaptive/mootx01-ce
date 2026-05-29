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
