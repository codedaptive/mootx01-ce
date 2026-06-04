//! CacheInvalidator: drives external invalidation of a `CachingRowStore`
//! from `StorageObserver` change events.
//!
//! Mirrors Swift's `CacheInvalidator`. Used when an external writer
//! (one that bypasses the `CachingRowStore` instance) mutates the
//! backing store, ensuring the hot tier never serves stale data.
//!
//! Rust's `StorageObserver` delivers changes via `std::sync::mpsc::Receiver`.
//! Two modes are provided:
//!
//!   - `process_pending()` — drain all ready messages without blocking.
//!     Useful in test code where the caller controls ordering.
//!   - `run_to_completion()` — block until the sender closes (channel
//!     disconnected). Intended for background threads:
//!     `std::thread::spawn(move || invalidator.run_to_completion())`.
//!
//! Both modes call `CachingRowStore::invalidate` for each `TableChange`,
//! which evicts the affected row (or the whole table when `row_key` is
//! `None`).

use crate::caching_row_store::CachingRowStore;
use crate::observer::TableChange;
use std::sync::{mpsc::Receiver, Arc};

/// Drives external invalidation of a `CachingRowStore` from a stream of
/// `TableChange` events. Create via `CacheInvalidator::new`.
pub struct CacheInvalidator {
    cache: Arc<CachingRowStore>,
    receiver: Receiver<TableChange>,
}

impl CacheInvalidator {
    /// Bind `receiver` to `cache`. Does not start background processing;
    /// call `process_pending()` in a loop or `run_to_completion()` in a
    /// dedicated thread.
    pub fn new(cache: Arc<CachingRowStore>, receiver: Receiver<TableChange>) -> Self {
        CacheInvalidator { cache, receiver }
    }

    /// Drain all currently-available messages without blocking. Returns the
    /// number of invalidations applied. Useful in tests where the caller
    /// controls sequencing.
    pub fn process_pending(&self) -> usize {
        let mut count = 0;
        loop {
            match self.receiver.try_recv() {
                Ok(change) => {
                    self.cache.invalidate(change.table.as_str(), change.row_key);
                    count += 1;
                }
                Err(_) => break,
            }
        }
        count
    }

    /// Block until the sender side of the channel is closed (disconnected),
    /// processing every `TableChange` as it arrives. Suitable for running on
    /// a background thread:
    ///
    /// ```ignore
    /// let invalidator = CacheInvalidator::new(cache.clone(), receiver);
    /// std::thread::spawn(move || invalidator.run_to_completion());
    /// ```
    pub fn run_to_completion(self) {
        while let Ok(change) = self.receiver.recv() {
            self.cache.invalidate(change.table.as_str(), change.row_key);
        }
    }
}
