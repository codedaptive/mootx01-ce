// EncoderModelSeed.swift
//
// Hardcoded seed values for the bundled arctic-embed-s-w60 encoder model.
// Used by `mootx01 upgrade` (and estate provisioning) to INSERT a row
// into the `encoder_models` table when none exists.
//
// The registry row (`EncoderModelRow`) and CorpusKit's `EncoderModelSpec`
// carry the same fields; both are constructed from these constants.
//
// To swap the winner (a different model ID from the audition):
//   1. Update all constants below to match the new model's manifest.
//   2. Re-run tools/encoder-models/build-all.sh.
//   3. Replace the model directory in app resources and installer package.
//   Schema migration and re-encode are handled by EncoderModelStore
//   and the drain duty — this file is only the seed source.

/// Static seed values for the bundled snowflake-arctic-embed-s encoder model.
///
/// `mootx01 upgrade` and estate provisioning call
/// `EncoderModelStore.upsert(_:)` with a row constructed from these
/// constants. `is_active` is set to 1 only when no active row exists in
/// `encoder_models`.
public enum EncoderModelSeed {

    // MARK: - Model identity

    /// The model ID, format `<model>-w<window_words>` per contract §1.
    /// Changing the window size requires a new model ID and a full re-index.
    public static let modelID: String = "arctic-embed-s-w60"

    /// Full pinned HF commit hash. A weights revision bump is a new
    /// `model_version` and triggers a re-index via the drain duty.
    public static let modelVersion: String = "e596f507467533e48a2e17c007f0e1dacc837b33"

    /// Output dimension of snowflake-arctic-embed-s.
    public static let dim: Int = 384

    /// Arctic card query instruction; documents receive no prefix.
    public static let queryPrefix: String = "Represent this sentence for searching relevant passages: "

    /// No document prefix.
    public static let docPrefix: String = ""

    /// Pooling strategy stored in the registry row.
    public static let pooling: String = "cls"

    /// sha256(vocab.txt) at pinned HF revision e596f507467533e48a2e17c007f0e1dacc837b33.
    /// Verified by ModelDirectoryResolver at load time; stored in
    /// encoder_models.tokenizer_hash. Identical across Apple and Linux/Windows
    /// manifests because both platforms ship the same vocab file.
    public static let tokenizerHash: String =
        "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"

    // MARK: - Span parameters

    /// Sliding-window width in words. Encoded in the model ID ("w60").
    public static let windowWords: Int = 60

    /// step = windowWords / overlapDivisor = 30 words of stride.
    public static let overlapDivisor: Int = 2

    /// Hard ceiling on spans per drawer: 32 spans × 384 bytes = 12 KB.
    public static let maxSpans: Int = 32

    /// Model max-sequence in tokens (snowflake-arctic-embed-s max_position_embeddings).
    public static let maxSequence: Int = 512
}
