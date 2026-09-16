//! Provider-neutral source-grounded fact extraction contract.
//! Swift mirror: `Sources/FactExtractionKit`.

pub mod contract;
pub mod continuation;
pub mod grounding;

pub use contract::*;
pub use continuation::*;
pub use grounding::*;
