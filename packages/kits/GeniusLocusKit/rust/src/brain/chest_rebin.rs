//! brain/chest_rebin.rs — the chest re-bin duty (ADR-026; GENIUSLOCUSKIT_SPEC
//! § DUTY_LIFECYCLE "Chest re-bin is a Class B duty", LocusKit spec § 12).
//! Twin of ChestRebin.swift.
//!
//! A room is owed a re-bin when any of its containers (a chest, or the room
//! itself while it holds drawers directly) is at or above
//! `chest_placement::CAPACITY`. One batch re-bins `chest_rebin_batch` such
//! rooms whole through `Estate::rebin_room`: one sort, one transaction, one
//! audit event. Afterwards the room's anomaly rosters are reconciled: rows
//! of containers the re-bin retired are deleted, and every container still
//! standing is marked owed so the sweep re-reads its membership. New chests
//! have no row and are owed by construction.
//!
//! The anomaly sweep never scores a container at capacity (it skips it and
//! leaves it to this duty), so `mootx01 drain` settles this duty before the
//! sweep and a finished estate has no oversized container.

use std::collections::BTreeSet;

use crate::brain::anomaly_flag_sweep::{containers_of, mark_container_dirty, roster_id};
use crate::coordinator::{EstateCoordinator, GeniusLocusKitError};
use crate::handle::EstateHandle;
use engram_lib::chest_placement;
use queuekit::StreamId;

fn failure(error: impl std::fmt::Debug) -> GeniusLocusKitError {
    GeniusLocusKitError::UnderlyingEstateFailure { reason: format!("{error:?}") }
}

impl EstateCoordinator {
    /// The rooms owed a re-bin: any container at or above capacity. Twin of
    /// Swift `chestRebinOwedRooms`.
    pub fn chest_rebin_owed_rooms(&self, handle: &EstateHandle) -> Result<Vec<(String, String)>, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?;
        let mut owed = Vec::new();
        for entry in estate.room_level_fingerprints().map_err(failure)? {
            let containers = estate.containers_in(&entry.wing, &entry.room).map_err(failure)?;
            if containers.iter().any(|c| c.count >= chest_placement::CAPACITY) {
                owed.push((entry.wing, entry.room));
            }
        }
        Ok(owed)
    }

    /// One re-bin batch: up to `limit` owed rooms, each re-binned whole.
    /// Returns the rooms re-binned; the duty queue carries the rest forward.
    /// `now` is epoch milliseconds. Twin of Swift `runChestRebinBatch`.
    pub fn run_chest_rebin_batch(&self, handle: &EstateHandle, limit: usize, now: i64) -> Result<usize, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?;
        let checkpoints = self.fact_checkpoints(handle)?;
        let stream = StreamId("anomaly-sweep-checkpoints".into());
        let mut rebinned = 0usize;
        for (wing, room) in self.chest_rebin_owed_rooms(handle)?.into_iter().take(limit) {
            let before: BTreeSet<String> = estate
                .containers_in(&wing, &room)
                .map_err(failure)?
                .into_iter()
                .map(|c| c.chest_node_id.to_lowercase())
                .collect();
            estate.rebin_room(&wing, &room, now).map_err(failure)?;
            let after = containers_of(estate, &wing, &room).map_err(failure)?;
            let standing: BTreeSet<String> = after.iter().map(|(c, _)| c.node_id.to_lowercase()).collect();
            for retired in before.difference(&standing) {
                checkpoints.delete(&roster_id(retired), &stream).map_err(failure)?;
            }
            for (container, _) in &after {
                mark_container_dirty(&checkpoints, container, now)?;
            }
            rebinned += 1;
        }
        Ok(rebinned)
    }
}
