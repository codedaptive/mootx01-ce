// brain/anomaly_flag_sweep.rs — Rust twin of AnomalyFlagSweep.swift.
//
// Room-cohesion anomaly-flag sweep for GeniusLocusKit (§11.18,
// anomalous-flag recall prefilter).
//
// Scores each drawer's mean shingle-similarity to its room peers,
// derives z-scores from the room's cohesion distribution, and
// sets/clears bit 26 (`is_anomalous()`) of `operational_bitmap`.
//
// Design mirrors the Swift reference exactly:
//   • Room minimum size: 3 drawers (z-score not meaningful for < 3 peers)
//   • Cohesion metric: mean char-3-shingle Jaccard to all room peers
//   • Gate: z-score ≤ −threshold (low-cohesion outlier) → is_anomalous = true
//   • Default threshold: 2.0 (≈ 2σ below-mean cutoff)
//   • Derived signal: no audit event, no lifecycle/lineage field touched
//   • Complexity: O(n²) per room, so the resident never scores the whole
//     estate at once: the sweep is a row-debt DUTY (§ DUTY_LIFECYCLE) whose
//     debt is the set of rooms touched since they were last scored, found by
//     folding the estate's audit events; a batch scores a bounded number of
//     owed rooms. `anomaly_flag_sweep` on the coordinator remains the
//     whole-estate form (tests, operator tooling).
//   • Idempotent: skip-write when bit is already in the correct state
//
// SubstrateML provides `AnomalyDetection::z_score` and
// `shingle_similarity::similarity` — both are conformance-gated,
// byte-identical with the Swift port.
//
// GOLDEN PIN (cross-port): the planted-outlier fixture in
// `tests/anomaly_sweep_parity.rs` asserts that a known outlier room
// produces exactly 1 changed drawer on both Swift and Rust with the same
// content. The fixture uses the same cohort content from
// AnomalyFlagSweepTests.swift so both ports assert the same invariant
// against the same input.

/// Minimum drawers per room to run the z-score computation (§11.18).
///
/// Below this threshold the standard deviation is either zero or
/// statistically unstable. All drawers in under-threshold rooms have
/// bit 26 cleared — not anomalous by definition. Mirrors Swift
/// `GeniusLocusKit.anomalySweepMinRoomSize`.
pub const ANOMALY_SWEEP_MIN_ROOM_SIZE: usize = 3;

/// Default z-score threshold for the negative-cohesion anomaly gate (§11.18).
///
/// A drawer is flagged anomalous when its cohesion z-score ≤ −threshold.
/// Default 2.0 balances sensitivity against false-positive rate. Mirrors
/// Swift `GeniusLocusKit.anomalySweepDefaultThreshold`.
pub const ANOMALY_SWEEP_DEFAULT_THRESHOLD: f32 = 2.0;

use crate::{
    coordinator::{EstateCoordinator, GeniusLocusKitError},
    handle::EstateHandle,
};
use locus_kit::{error::LocusKitError, estate::Estate, provenance::Sensitivity};
use queuekit::{JobId, StreamId, HLC};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use substrate_ml::anomaly::AnomalyDetection;
use substrate_ml::shingle_similarity;

/// Score one room: set/clear bit 26 on each of its drawers from the room's
/// cohesion distribution. Returns the count of drawers whose bit changed.
/// Shared by the whole-estate sweep and the incremental duty.
pub fn score_room(
    estate: &Estate,
    wing: &str,
    room: &str,
    threshold: f32,
    now: i64,
) -> Result<usize, LocusKitError> {
    let mut changed: usize = 0;
    // Sensitivity cohort gate (codex finding 2026-08-26):
    // restricted/secret drawers are EXCLUDED from the cohesion
    // cohort entirely — they neither receive bit 26 nor influence
    // any other drawer's score. Including them let a caller without
    // a sensitivity grant plant visible probe rows and read
    // anomalous_filter results to observe lexical similarity to
    // hidden content. Excluded rows also get any stale bit 26
    // cleared. Twin of the Swift AnomalyFlagSweep gate.
    let mut drawers = Vec::new();
    for drawer in estate.drawers_in_wing_room(wing, room)? {
        let s = drawer.sensitivity();
        if s == Sensitivity::Restricted || s == Sensitivity::Secret {
            if drawer.is_anomalous() {
                changed += estate.set_anomalous_flag(&drawer.id, false, now)?;
            }
        } else {
            drawers.push(drawer);
        }
    }
    if drawers.is_empty() {
        return Ok(changed);
    }
    if drawers.len() < ANOMALY_SWEEP_MIN_ROOM_SIZE {
        // Too few peers for a meaningful z-score: the room has no cohesion
        // baseline, so nothing in it is anomalous by definition.
        for drawer in &drawers {
            if drawer.is_anomalous() {
                changed += estate.set_anomalous_flag(&drawer.id, false, now)?;
            }
        }
        return Ok(changed);
    }

    // Per-drawer cohesion = mean char-3-shingle Jaccard to every other
    // drawer in the room; shingle sets are precomputed once per drawer.
    // Conformance-gated byte-identical with the Swift ShingleSimilarity leg.
    let count = drawers.len();
    let shingle_sets: Vec<_> = drawers
        .iter()
        .map(|d| shingle_similarity::shingles(&d.content))
        .collect();
    let mut cohesion: Vec<f32> = vec![0.0; count];
    for i in 0..count {
        let mut sum: f32 = 0.0;
        for j in 0..count {
            if i != j {
                sum += shingle_similarity::similarity_sets(&shingle_sets[i], &shingle_sets[j]);
            }
        }
        // (count - 1) peers; safe because count >= ANOMALY_SWEEP_MIN_ROOM_SIZE.
        cohesion[i] = sum / (count - 1) as f32;
    }
    let n = count as f32;
    let mean: f32 = cohesion.iter().sum::<f32>() / n;
    let variance: f32 = cohesion.iter().map(|x| (x - mean) * (x - mean)).sum::<f32>() / n;
    let stddev = variance.sqrt();
    // Anomalous = low-cohesion outlier: z ≤ −threshold. z_score returns 0
    // when stddev == 0 (all identical content), so nothing is flagged then.
    for (idx, drawer) in drawers.iter().enumerate() {
        let z = AnomalyDetection::z_score(cohesion[idx], mean, stddev);
        changed += estate.set_anomalous_flag(&drawer.id, z <= -threshold, now)?;
    }
    Ok(changed)
}

// ─── Incremental duty form (§ DUTY_LIFECYCLE) ──────────────────────────────

/// Checkpoint stream for the incremental sweep: one `cursor` row (the last
/// audit HLC folded into room dirtiness) and one row per room (dirty or
/// not). Lives in the estate's queue database beside the other duty state;
/// no schema, no migration. A room with no row has never been scored and is
/// owed. Twin of Swift `anomalySweepStream`.
fn stream() -> StreamId {
    StreamId("anomaly-sweep-checkpoints".into())
}
fn cursor_id() -> JobId {
    JobId("cursor".into())
}
fn room_id(wing: &str, room: &str) -> JobId {
    JobId(super::fact_extraction_duty::source_digest(&format!("anomaly-room-v1|{wing}/{room}"))[..32].into())
}
/// Audit events folded per debt read; bounded so a burst of writes costs a
/// few passes, never one long one.
const AUDIT_FOLD: usize = 2_000;

/// The cursor HLC stored as three ints (the HLC type's own serde is behind a
/// feature; this shape is the one both ports write).
#[derive(Serialize, Deserialize)]
struct Cursor {
    physical_time: i64,
    logical_count: i32,
    node_id: i32,
}
#[derive(Serialize, Deserialize)]
struct RoomState {
    wing: String,
    room: String,
    dirty: bool,
}
fn stamp(now: i64) -> HLC {
    HLC { physical_time: now, logical_count: 0, node_id: 0 }
}
fn failure(error: impl std::fmt::Debug) -> GeniusLocusKitError {
    GeniusLocusKitError::UnderlyingEstateFailure { reason: format!("{error:?}") }
}

impl EstateCoordinator {
    /// The rooms owed a scoring: fold every audit event since the cursor into
    /// room dirtiness (a write to any drawer dirties its room), then list the
    /// rooms that are dirty or have never been scored. This is the duty's debt
    /// count and its work list. Twin of Swift `anomalySweepOwedRooms`.
    pub fn anomaly_sweep_owed_rooms(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<Vec<(String, String)>, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?;
        let checkpoints = self.fact_checkpoints(handle)?;
        let stream = stream();

        // 1. Fold new audit events into dirty rooms, advancing the cursor.
        let mut cursor_data = checkpoints.read(&cursor_id(), &stream).map_err(failure)?;
        let mut after: Option<HLC> = match &cursor_data {
            Some(data) => {
                let c: Cursor = serde_json::from_slice(data).map_err(failure)?;
                Some(HLC { physical_time: c.physical_time, logical_count: c.logical_count, node_id: c.node_id })
            }
            None => None,
        };
        let mut folds = 0;
        while folds < 8 {
            let events = estate.audit_events(after, AUDIT_FOLD).map_err(failure)?;
            let Some(last) = events.last() else { break };
            // Audit rows carry the drawer UUID as a u128; drawer ids are the
            // hyphenated spelling, lowercase in this port and uppercase in the
            // Swift port, so both spellings are asked for.
            let mut ids: BTreeSet<String> = BTreeSet::new();
            for event in &events {
                let text = uuid::Uuid::from_u128(event.row_id.0).hyphenated().to_string();
                ids.insert(text.to_uppercase());
                ids.insert(text);
            }
            let id_refs: Vec<&str> = ids.iter().map(String::as_str).collect();
            let drawers = estate.get_drawers(&id_refs).map_err(failure)?;
            let names = resolve_room_names(&estate, drawers.iter().map(|d| d.parent_node_id.as_str()));
            let mut touched: BTreeSet<String> = BTreeSet::new();
            for drawer in &drawers {
                let Some((wing, room)) = names.get(&drawer.parent_node_id) else { continue };
                if !touched.insert(format!("{wing}/{room}")) {
                    continue;
                }
                let id = room_id(wing, room);
                let previous = checkpoints.read(&id, &stream).map_err(failure)?;
                let state = RoomState { wing: wing.clone(), room: room.clone(), dirty: true };
                checkpoints
                    .compare_and_swap(&id, &stream, previous.as_deref(),
                        &serde_json::to_vec(&state).map_err(failure)?, stamp(now))
                    .map_err(failure)?;
            }
            let next = serde_json::to_vec(&Cursor {
                physical_time: last.hlc.physical_time,
                logical_count: last.hlc.logical_count,
                node_id: last.hlc.node_id,
            })
            .map_err(failure)?;
            checkpoints
                .compare_and_swap(&cursor_id(), &stream, cursor_data.as_deref(), &next, stamp(now))
                .map_err(failure)?;
            after = Some(last.hlc);
            cursor_data = Some(next);
            folds += 1;
            if events.len() < AUDIT_FOLD {
                break;
            }
        }

        // 2. Owed = dirty or never scored.
        let mut known: BTreeMap<String, bool> = BTreeMap::new();
        for payload in checkpoints.payloads(&stream).map_err(failure)? {
            if let Ok(state) = serde_json::from_slice::<RoomState>(&payload) {
                known.insert(format!("{}/{}", state.wing, state.room), state.dirty);
            }
        }
        let mut owed = Vec::new();
        for entry in estate.room_level_fingerprints().map_err(failure)? {
            if *known.get(&format!("{}/{}", entry.wing, entry.room)).unwrap_or(&true) {
                owed.push((entry.wing, entry.room));
            }
        }
        Ok(owed)
    }

    /// Score up to `limit` owed rooms and mark them clean. Returns the rooms
    /// scored; the duty queue carries the remainder forward. Twin of Swift
    /// `runAnomalySweepBatch`.
    pub fn run_anomaly_sweep_batch(
        &self,
        handle: &EstateHandle,
        limit: usize,
        now: i64,
    ) -> Result<usize, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?;
        let checkpoints = self.fact_checkpoints(handle)?;
        let stream = stream();
        let mut scored = 0;
        for (wing, room) in self.anomaly_sweep_owed_rooms(handle, now)?.into_iter().take(limit) {
            score_room(&estate, &wing, &room, ANOMALY_SWEEP_DEFAULT_THRESHOLD, now).map_err(failure)?;
            let id = room_id(&wing, &room);
            let previous = checkpoints.read(&id, &stream).map_err(failure)?;
            let clean = RoomState { wing, room, dirty: false };
            checkpoints
                .compare_and_swap(&id, &stream, previous.as_deref(),
                    &serde_json::to_vec(&clean).map_err(failure)?, stamp(now))
                .map_err(failure)?;
            scored += 1;
        }
        Ok(scored)
    }
}

/// Room node id → (wing, room) through the estate's node store; drawers whose
/// room cannot be resolved are skipped (an estate opened without a node tree).
fn resolve_room_names<'a>(
    estate: &Estate,
    parent_ids: impl Iterator<Item = &'a str>,
) -> BTreeMap<String, (String, String)> {
    let mut result = BTreeMap::new();
    let Some(node_store) = estate.node_store() else { return result };
    for pid in parent_ids.collect::<BTreeSet<_>>() {
        let Ok(room_uuid) = uuid::Uuid::parse_str(pid) else { continue };
        let Ok(Some(room_node)) = node_store.get_node(room_uuid) else { continue };
        let wing = room_node
            .parent_id
            .and_then(|w| node_store.get_node(w).ok().flatten())
            .map(|w| w.display_name)
            .unwrap_or_default();
        result.insert(pid.to_string(), (wing, room_node.display_name));
    }
    result
}
