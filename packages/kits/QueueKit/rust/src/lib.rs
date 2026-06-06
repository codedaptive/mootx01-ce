// QueueKit Rust parallel.
//
// FilesystemBackend: QUEUEKIT_SPEC §5,6,8,9 — byte-identical to Swift.
// PersistenceKitBackend: QUEUEKIT_SPEC §10 — behaviour-conformant,
//   gated on "persistencekit" feature (pulls in persistence-kit crate).
// ToolName: QUEUEKIT_SPEC §9 — allowlist validation type, present in
//   both default and persistencekit builds.

pub mod error;
pub mod job;
pub mod backend;
pub mod filesystem;

#[cfg(feature = "persistencekit")]
pub mod persistencekit;

pub use error::QueueError;
pub use job::{
    ArtifactRef, CodableValue, HLC, Job, JobId, ObservationStatus, SessionId,
    SignalFile, StreamId, ToolName,
    base64url_encode, base64url_decode,
    encode_job, encode_signal, filename_for_job, sortable_hlc,
};
pub use backend::QueueBackend;
pub use filesystem::FilesystemBackend;

#[cfg(feature = "persistencekit")]
pub use persistencekit::{
    PersistenceKitBackend, QueueKitSchema, QUEUE_KIT_TABLE_NAME,
};
