//! Encoder contract: the registry-row value type, the span windowing rule,
//! the `SpanEncoder` trait and the concrete provider-backed encoder; and the
//! cross-encoder contract: the packaged profile, the `PairScorer` trait, the
//! concrete provider-backed scorer and the request-borne `RerankDirective`.
//!
//! Mirror of Swift `Sources/CorpusKit/Encoder/`. The factories that turn a
//! model directory into a `SpanEncoder` or a `PairScorer` live in
//! `corpus-kit-providers` (`SpanEncoderFactory`, `PairScorerFactory`)
//! because they instantiate the candle runtime; this module holds only what
//! the recall stages and the duty need to name.

pub mod cross_encoder_profile;
pub mod pair_scorer;
pub mod rerank_directive;
pub mod span_encoder;
pub mod spanner;
pub mod spec;

pub use cross_encoder_profile::CrossEncoderProfile;
pub use pair_scorer::{PairInference, PairScorer, ProviderPairScorer, DEFAULT_PAIR_BATCH_SIZE};
pub use rerank_directive::{RerankAction, RerankDirective};
pub use span_encoder::{
    EmbeddingProviderSpanInference, EncoderError, ProviderSpanEncoder, SpanEncoder,
    SpanInference, DEFAULT_ENCODER_BATCH_SIZE,
};
pub use spec::{EncoderModelSpec, Pooling};
