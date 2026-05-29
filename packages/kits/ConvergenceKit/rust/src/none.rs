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
use std::sync::{Arc, Mutex};
use persistence_kit::Storage;

struct NoneState {
    enabled: bool,
    manifest: Option<SyncManifest>,
}

pub struct NoSyncEngine {
    state: Mutex<NoneState>,
}

impl NoSyncEngine {
    pub fn new() -> Self {
        NoSyncEngine {
            state: Mutex::new(NoneState {
                enabled: false,
                manifest: None,
            }),
        }
    }
}

impl Default for NoSyncEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl SyncEngine for NoSyncEngine {
    fn enable(&self, manifest: SyncManifest, _storage: Arc<dyn Storage>) -> SyncResult<()> {
        let mut state = self.state.lock().unwrap();
        if state.enabled {
            return Err(SyncError::AlreadyEnabled);
        }
        state.manifest = Some(manifest);
        state.enabled = true;
        Ok(())
    }

    fn disable(&self) -> SyncResult<()> {
        let mut state = self.state.lock().unwrap();
        state.enabled = false;
        state.manifest = None;
        Ok(())
    }

    fn push(&self) -> SyncResult<SyncReceipt> {
        let state = self.state.lock().unwrap();
        if !state.enabled {
            return Err(SyncError::NotEnabled);
        }
        Ok(SyncReceipt::empty())
    }

    fn pull(&self) -> SyncResult<SyncReceipt> {
        let state = self.state.lock().unwrap();
        if !state.enabled {
            return Err(SyncError::NotEnabled);
        }
        Ok(SyncReceipt::empty())
    }

    fn subscribe(&self) -> Receiver<SyncEvent> {
        let (_tx, rx) = channel();
        // _tx is dropped immediately; rx will return Disconnected
        // on first recv. Mirrors Swift's immediate stream-finish.
        rx
    }

    fn state(&self) -> SyncState {
        let state = self.state.lock().unwrap();
        if let Some(ref m) = state.manifest {
            if state.enabled {
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
