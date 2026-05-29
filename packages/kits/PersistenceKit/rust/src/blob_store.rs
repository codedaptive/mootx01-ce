//! BlobStore trait.

use crate::error::StorageResult;

pub type BlobKey = String;

pub trait BlobStore: Send + Sync {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()>;
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>>;
    fn delete(&self, key: &str) -> StorageResult<()>;
    fn exists(&self, key: &str) -> StorageResult<bool>;
    fn size(&self, key: &str) -> StorageResult<Option<usize>>;
}
