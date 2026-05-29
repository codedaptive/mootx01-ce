// QueueBackend trait per QUEUEKIT_SPEC §4.

use crate::error::QueueError;
use crate::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};

pub trait QueueBackend: Send + Sync {
    fn write(&self, job: &Job) -> Result<(), QueueError>;
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError>;
    fn complete(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError>;
    fn in_flight(&self) -> Result<Vec<Job>, QueueError>;
    fn completed(&self, stream_id: Option<&StreamId>)
        -> Result<Vec<Job>, QueueError>;

    /// Watch for arriving jobs. Calls `handler` on each (Job, SessionId)
    /// pair as jobs become available. Blocks the calling thread until
    /// `handler` returns an error or until the watcher encounters a
    /// fatal error. Conforms to QUEUEKIT_SPEC §3 watch() semantics.
    ///
    /// The default implementation returns `BackendUnavailable` so that
    /// backends that have not yet implemented `watch()` fail cleanly
    /// rather than at link time. Conforming backends override.
    fn watch<F>(&self, _handler: F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync,
    {
        Err(QueueError::BackendUnavailable(
            "watch() not implemented for this backend".to_string()))
    }
}
