//! BlobStore trait.
//!
//! REPLICATION NOTE:
//!   `list_keys()` is required by the full-snapshot replication primitive to
//!   enumerate all stored blob keys before copying them. Without it the
//!   replication layer has no way to discover keys without knowing them in
//!   advance, so the method is part of the core trait.

use crate::error::StorageResult;

pub type BlobKey = String;

pub trait BlobStore: Send + Sync {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()>;
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>>;
    fn delete(&self, key: &str) -> StorageResult<()>;
    fn exists(&self, key: &str) -> StorageResult<bool>;
    fn size(&self, key: &str) -> StorageResult<Option<usize>>;
    /// Return all keys currently stored in the blob store.
    ///
    /// Required by the full-snapshot replication primitive to enumerate blobs
    /// for copy. An empty store returns an empty Vec with no error.
    fn list_keys(&self) -> StorageResult<Vec<BlobKey>>;
}
