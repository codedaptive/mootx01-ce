//! Concrete FactExtractionKit providers.
//!
//! The NuExtract runtime lives in a short-lived worker process rather than the
//! server. The client is always available; building the worker binary requires
//! the `candle` feature. Model assets are local files supplied by the host.

pub mod protocol;
pub mod worker_client;

#[cfg(feature = "candle")]
pub mod candle_nuextract;
#[cfg(feature = "candle")]
pub mod worker_command;

pub use protocol::{NuExtractArchitecture, WorkerRequest, WorkerResponse, PROTOCOL_VERSION};
pub use worker_client::{NuExtractWorkerClient, NuExtractWorkerConfig};
