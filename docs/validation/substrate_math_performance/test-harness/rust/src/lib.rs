// src/lib.rs
//
// Library crate for the GeniusLocus reference test harness.
//
// Mirrors the Swift harness at
// `docs/validation/substrate_math_performance/test-harness/swift/`.
// Both produce vector files that the other validates, and the CRC32
// over the canonical binary serialization is the conformance gate.

pub mod harness;
pub mod primitives;

pub use harness::kernel_selector;
pub use harness::hardware;
pub use harness::kernel_registry;

pub use harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, f64_hex, u32_hex, u64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonReader, JsonValue, JsonWriter, VectorCase, VectorFile,
        FORMAT_VERSION, HARNESS_VERSION,
    },
};

pub use primitives::{
    registry::{find_primitive, all_primitives, PrimitiveDescriptor, ValidationResult},
    simhash::SimHashPrimitive,
};
