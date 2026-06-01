//! NoSyncEngine: passthrough backend. enable/disable succeed
//! trivially; push/pull return empty receipts; subscribe returns
//! a never-emitting receiver.
//!
//! Used when sync is structurally not wanted (development,
//! tests, deployments without iCloud or federation).

use crate::engine::SyncEngine;
use crate::types::{SyncError, SyncEvent, SyncReceipt, SyncResult, SyncState};
use crate::SyncManifest;
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use persistence_kit::Storage;

struct NoneState {
    enabled: bool,
    manifest: Option<SyncManifest>,
}

pub struct NoSyncEngine {
    state: NoneState,
}

impl NoSyncEngine {
    pub fn new() -> Self {
        NoSyncEngine {
            state: NoneState {
                enabled: false,
                manifest: None,
            },
        }
    }
}

impl Default for NoSyncEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl SyncEngine for NoSyncEngine {
    fn enable(&mut self, manifest: SyncManifest, _storage: Arc<dyn Storage>) -> SyncResult<()> {
        if self.state.enabled {
            return Err(SyncError::AlreadyEnabled);
        }
        self.state.manifest = Some(manifest);
        self.state.enabled = true;
        Ok(())
    }

    fn disable(&mut self) -> SyncResult<()> {
        self.state.enabled = false;
        self.state.manifest = None;
        Ok(())
    }

    fn push(&mut self) -> SyncResult<SyncReceipt> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        Ok(SyncReceipt::empty())
    }

    fn pull(&mut self) -> SyncResult<SyncReceipt> {
        if !self.state.enabled {
            return Err(SyncError::NotEnabled);
        }
        Ok(SyncReceipt::empty())
    }

    fn subscribe(&mut self) -> Receiver<SyncEvent> {
        let (_tx, rx) = channel();
        // _tx is dropped immediately; rx returns Disconnected on first
        // recv — the no-sync backend emits no events.
        rx
    }

    fn state(&self) -> SyncState {
        if let Some(ref m) = self.state.manifest {
            if self.state.enabled {
                return SyncState::Enabled {
                    zone: m.zone_identifier.clone(),
                    last_push_secs: None,
                    last_pull_secs: None,
                };
            }
        }
        SyncState::Disabled
    }
}
