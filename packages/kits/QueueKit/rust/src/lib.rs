// QueueKit Rust parallel.
//
// FilesystemBackend per QUEUEKIT_SPEC §5,6,8,9. PersistenceKitBackend
// is declared in persistencekit.rs but is behavior-conformant only
// (not byte-identical), per spec §12 bit-identity requirement.

pub mod error;
pub mod job;
pub mod backend;
pub mod filesystem;

#[cfg(feature = "persistencekit")]
pub mod persistencekit;

pub use error::QueueError;
pub use job::{
    ArtifactRef, CodableValue, HLC, Job, JobId, ObservationStatus, SessionId,
    SignalFile, StreamId, base64url_encode, base64url_decode,
    encode_job, encode_signal, filename_for_job, sortable_hlc,
};
pub use backend::QueueBackend;
pub use filesystem::FilesystemBackend;
