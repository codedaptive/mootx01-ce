// QueueError per spec §7.

use std::fmt;

#[derive(Debug)]
pub enum QueueError {
    DirectoryCreationFailed(String),
    WriteFailed(String),
    RenameFailed { from: String, to: String, msg: String },
    DecodingFailed(String),
    JobNotFound(String),
    WatcherFailed(String),
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
