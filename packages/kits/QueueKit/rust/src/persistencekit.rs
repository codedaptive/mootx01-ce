// PersistenceKitBackend (Rust) — declared per spec §10. Behavior-
// conformant only; not byte-identical (spec §12 bit-identity
// applies to FilesystemBackend wire format only).
//
// A complete Rust PersistenceKit integration is out of scope for Phase 1
// per the time budget; the trait surface is here so consumers can
// switch on the feature flag.

use crate::backend::QueueBackend;
use crate::error::QueueError;
use crate::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};

#[allow(dead_code)]
pub struct PersistenceKitBackend;

impl PersistenceKitBackend {
    pub fn new() -> Self { Self }
}

impl QueueBackend for PersistenceKitBackend {
    fn write(&self, _job: &Job) -> Result<(), QueueError> {
        Err(QueueError::BackendUnavailable(
            "Rust PersistenceKitBackend not implemented in Phase 1; spec §10 \
             behavior-conformant integration is reserved for a follow-up \
             mission per the Forge daemon parity doctrine.".into()))
    }
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError> {
        Err(QueueError::BackendUnavailable("see write()".into()))
    }
    fn complete(&self, _: &JobId, _: ObservationStatus, _: Vec<ArtifactRef>)
        -> Result<(), QueueError> {
        Err(QueueError::BackendUnavailable("see write()".into()))
    }
    fn in_flight(&self) -> Result<Vec<Job>, QueueError> { Ok(vec![]) }
    fn completed(&self, _: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        Ok(vec![])
    }
}
