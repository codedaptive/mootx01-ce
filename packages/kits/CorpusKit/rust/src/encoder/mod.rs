//! Encoder contract: the registry-row value type, the span windowing rule,
//! the `SpanEncoder` trait and the concrete provider-backed encoder.
//!
//! Mirror of Swift `Sources/CorpusKit/Encoder/`. The factory that turns a
//! model directory into a `SpanEncoder` lives in `corpus-kit-providers`
//! (`SpanEncoderFactory`) because it instantiates the candle provider; this
//! module holds only what the recall stage and the duty need to name.

pub mod span_encoder;
pub mod spanner;
pub mod spec;

pub use span_encoder::{
    EmbeddingProviderSpanInference, EncoderError, ProviderSpanEncoder, SpanEncoder,
    SpanInference, DEFAULT_ENCODER_BATCH_SIZE,
};
pub use spec::{EncoderModelSpec, Pooling};
