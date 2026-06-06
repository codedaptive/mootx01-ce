// QueueError per spec §7.
//
// Variants mirror Swift's QueueError case-for-case with Rust idiom
// adjustments:
//   - Associated values carry String (not typed wrappers) because
//     QueueError is returned across the QueueBackend trait boundary
//     where type-erased error context is most useful.
//   - UnknownTool carries the raw tool name string (Swift carries ToolName).
//   - StaleTmpFile carries (path, age_secs) matching Swift's (path, age).

use std::fmt;

#[derive(Debug)]
pub enum QueueError {
    DirectoryCreationFailed(String),
    WriteFailed(String),
    RenameFailed { from: String, to: String, msg: String },
    DecodingFailed(String),
    /// A ToolName was not found in the allowlist (Swift: unknownTool(ToolName)).
    UnknownTool(String),
    JobNotFound(String),
    WatcherFailed(String),
    /// A tmp/ file is older than the stale-sweep threshold.
    /// `age_secs` mirrors Swift's TimeInterval (f64 seconds).
    StaleTmpFile { path: String, age_secs: f64 },
    BackendUnavailable(String),
    InvalidTerminalStatus(String),
}

impl fmt::Display for QueueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}

impl std::error::Error for QueueError {}

impl From<std::io::Error> for QueueError {
    fn from(e: std::io::Error) -> Self {
        QueueError::WriteFailed(e.to_string())
    }
}

impl From<serde_json::Error> for QueueError {
    fn from(e: serde_json::Error) -> Self {
        QueueError::DecodingFailed(e.to_string())
    }
}
