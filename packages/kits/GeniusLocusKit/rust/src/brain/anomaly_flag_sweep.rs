// brain/anomaly_flag_sweep.rs — Rust twin of AnomalyFlagSweep.swift.
//
// Container-cohesion anomaly-flag sweep for GeniusLocusKit (§11.18,
// anomalous-flag recall prefilter; ADR-026, spec § CHESTS).
//
// Scores each drawer's mean shingle-similarity to its peers in the same
// CONTAINER (a chest, or the room itself while the room has never been
// re-binned), derives z-scores from the container's cohesion distribution,
// and sets/clears bit 26 (`is_anomalous()`) of `operational_bitmap`.
//
// Design mirrors the Swift reference exactly:
//   • Container minimum size: 3 drawers (z-score not meaningful for < 3 peers)
//   • Cohesion metric: mean char-3-shingle Jaccard to all container peers
//   • Gate: z-score ≤ −threshold (low-cohesion outlier) → is_anomalous = true
//   • Default threshold: 2.0 (≈ 2σ below-mean cutoff)
//   • Derived signal: no audit event, no lifecycle/lineage field touched
//   • Incremental: a roster row per container (queue checkpoint store,
//     stream `anomaly-sweep-checkpoints`) keeps every member's exact
//     integer sum of quantised similarities to its peers (CohesionRoster).
//     A write that adds or removes a drawer costs one pass over the
//     container, not a square; the square is paid once, on a container's
//     first scoring, and a container is at most `CAPACITY` drawers, so it
//     is bounded. A container at or above capacity is not scored: its room
//     is owed a re-bin (chest_rebin.rs) instead.
//   • Fallback: a member whose old content cannot be recovered (expunged,
//     or a digest that no longer matches) rescores the container whole and
//     replaces the roster.
//   • Idempotent: skip-write when bit is already in the correct state
//
// SubstrateML provides `AnomalyDetection::z_score`,
// `shingle_similarity` and `CohesionRoster` — conformance-gated,
// byte-identical with the Swift port.
//
// GOLDEN PIN (cross-port): the planted-outlier fixture in
// `tests/anomaly_sweep_duty_parity.rs` asserts that a known outlier
// container produces exactly 1 flagged drawer on both Swift and Rust with
// the same content.

/// Minimum drawers per container to run the z-score computation (§11.18).
///
/// Below this threshold the standard deviation is either zero or
/// statistically unstable. All drawers in under-threshold containers have
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
use engram_lib::chest_placement;
use locus_kit::{adjectives::AdjectiveSensitivity, error::LocusKitError, estate::Estate};
use queuekit::{JobId, QueueCheckpointStore, StreamId, HLC};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use substrate_ml::cohesion_roster::{CohesionRoster, RosterEntry};
use substrate_ml::shingle_similarity;

/// One unit of the anomaly sweep: a container (a chest, or a room holding
/// drawers directly) and the room it belongs to. Twin of Swift
/// `AnomalyContainer`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct AnomalyContainer {
    /// The container node id, the drawers' `parent_node_id`.
    pub node_id: String,
    pub wing: String,
    pub room: String,
}

// ─── Checkpoint rows ────────────────────────────────────────────────────────

/// Checkpoint stream for the incremental sweep: one `cursor` row (the last
/// audit HLC folded into container dirtiness) and one roster row per
/// container keyed by its node id. Lives in the estate's queue database
/// beside the other duty state; no schema, no migration. A container with
/// no row has never been scored and is owed. Twin of Swift
/// `anomalySweepStream`.
fn stream() -> StreamId {
    StreamId("anomaly-sweep-checkpoints".into())
}
fn cursor_id() -> JobId {
    JobId("cursor".into())
}
pub(crate) fn roster_id(container_node_id: &str) -> JobId {
    JobId(container_node_id.to_lowercase())
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

/// The roster row as both ports write it: the container, its room, whether
/// a write touched it since its last scoring, and the exact integer sums of
/// its members. `roster.entries` is the truth every pass reconciles against.
#[derive(Serialize, Deserialize)]
struct RosterRow {
    container: String,
    wing: String,
    room: String,
    dirty: bool,
    roster: RosterJson,
}
#[derive(Serialize, Deserialize, Default)]
struct RosterJson {
    entries: Vec<EntryJson>,
}
#[derive(Serialize, Deserialize)]
struct EntryJson {
    id: String,
    digest: String,
    sum: i64,
}
impl RosterJson {
    fn from_roster(roster: &CohesionRoster) -> Self {
        Self {
            entries: roster
                .entries()
                .iter()
                .map(|e| EntryJson { id: e.id.clone(), digest: e.digest.clone(), sum: e.sum })
                .collect(),
        }
    }
    fn to_roster(&self) -> CohesionRoster {
        CohesionRoster::new(
            self.entries
                .iter()
                .map(|e| RosterEntry { id: e.id.clone(), digest: e.digest.clone(), sum: e.sum })
                .collect(),
        )
    }
}

fn stamp(now: i64) -> HLC {
    HLC { physical_time: now, logical_count: 0, node_id: 0 }
}
fn failure(error: impl std::fmt::Debug) -> GeniusLocusKitError {
    GeniusLocusKitError::UnderlyingEstateFailure { reason: format!("{error:?}") }
}

/// The content digest a roster entry is scored under: a drawer whose digest
/// differs from its entry has different content than the sum was computed
/// with. Twin of Swift `anomalyContentDigest`.
pub(crate) fn content_digest(content: &str) -> String {
    super::fact_extraction_duty::source_digest(content)
}

fn read_roster(checkpoints: &QueueCheckpointStore, container_node_id: &str) -> Result<(Option<Vec<u8>>, Option<RosterRow>), GeniusLocusKitError> {
    let data = checkpoints.read(&roster_id(container_node_id), &stream()).map_err(failure)?;
    let row = match &data {
        Some(bytes) => Some(serde_json::from_slice::<RosterRow>(bytes).map_err(failure)?),
        None => None,
    };
    Ok((data, row))
}

fn write_roster(checkpoints: &QueueCheckpointStore, expected: Option<&[u8]>, row: &RosterRow, now: i64) -> Result<(), GeniusLocusKitError> {
    checkpoints
        .compare_and_swap(&roster_id(&row.container), &stream(), expected,
            &serde_json::to_vec(row).map_err(failure)?, stamp(now))
        .map_err(failure)?;
    Ok(())
}

/// Mark one container owed a scoring, keeping its roster so the next pass
/// is incremental. A container with no row yet gets an empty one (owed by
/// construction either way; the row records the room so the owed list can
/// name it). Twin of Swift `markAnomalySweepContainerDirty`.
pub(crate) fn mark_container_dirty(checkpoints: &QueueCheckpointStore, container: &AnomalyContainer, now: i64) -> Result<(), GeniusLocusKitError> {
    let (data, existing) = read_roster(checkpoints, &container.node_id)?;
    let mut row = existing.unwrap_or_else(|| RosterRow {
        container: container.node_id.to_lowercase(),
        wing: container.wing.clone(),
        room: container.room.clone(),
        dirty: true,
        roster: RosterJson::default(),
    });
    row.dirty = true;
    write_roster(checkpoints, data.as_deref(), &row, now)
}

/// Every container of a room, from the tree (chests, plus the room itself
/// while it holds drawers directly), with live counts.
pub(crate) fn containers_of(estate: &Estate, wing: &str, room: &str) -> Result<Vec<(AnomalyContainer, usize)>, LocusKitError> {
    Ok(estate
        .containers_in(wing, room)?
        .into_iter()
        .map(|r| (AnomalyContainer { node_id: r.chest_node_id, wing: wing.to_string(), room: room.to_string() }, r.count))
        .collect())
}

/// Score one container against its roster and write the flags that
/// flipped. `whole` rescores from nothing and replaces the roster;
/// otherwise the pass is a reconcile: members gone from the container are
/// removed from the sums (their content still present unless expunged),
/// members new to it are added, and only when a removed member's old
/// content cannot be recovered is the container rescored whole. Returns the
/// count of drawers whose bit 26 changed. Shared by the whole-estate sweep
/// and the incremental duty. Twin of Swift `scoreContainer`.
pub fn score_container(
    estate: &Estate,
    checkpoints: &QueueCheckpointStore,
    container: &AnomalyContainer,
    threshold: f32,
    whole: bool,
    now: i64,
) -> Result<usize, GeniusLocusKitError> {
    let mut changed: usize = 0;
    // Sensitivity cohort gate (codex finding 2026-08-26):
    // restricted/secret drawers are EXCLUDED from the cohesion cohort
    // entirely — they neither receive bit 26 nor influence any other
    // drawer's score. Including them let a caller without a sensitivity
    // grant plant visible probe rows and read anomalous_filter results to
    // observe lexical similarity to hidden content. Excluded rows also get
    // any stale bit 26 cleared. Twin of the Swift AnomalyFlagSweep gate.
    let mut drawers = Vec::new();
    for drawer in estate.drawers_in_container(&container.node_id).map_err(failure)? {
        // Adjective sensitivity: the field the read-side containment gate
        // enforces, so the cohort excludes exactly what an ungranted caller
        // cannot read (the provenance sensitivity is a separate field
        // capture does not set from the frame).
        let s = drawer.adjective_sensitivity();
        if s == AdjectiveSensitivity::Restricted || s == AdjectiveSensitivity::Secret {
            if drawer.is_anomalous() {
                changed += estate.set_anomalous_flag(&drawer.id, false, now).map_err(failure)?;
            }
        } else {
            drawers.push(drawer);
        }
    }
    // Members are visited in id order so the roster's entry order, and
    // therefore its row bytes, are the same on both ports.
    drawers.sort_by_key(|d| d.id.to_lowercase());

    let (roster_data, existing) = read_roster(checkpoints, &container.node_id)?;
    let mut row = existing.unwrap_or_else(|| RosterRow {
        container: container.node_id.to_lowercase(),
        wing: container.wing.clone(),
        room: container.room.clone(),
        dirty: true,
        roster: RosterJson::default(),
    });
    let stored = row.roster.to_roster();

    // The reconcile plan against the stored roster.
    let live: Vec<(String, String, &str)> = drawers
        .iter()
        .map(|d| (d.id.to_lowercase(), content_digest(&d.content), d.content.as_str()))
        .collect();
    let live_digest: BTreeMap<&str, &str> = live.iter().map(|(id, digest, _)| (id.as_str(), digest.as_str())).collect();
    let mut removed: Vec<(String, String)> = Vec::new();
    let mut kept: BTreeSet<String> = BTreeSet::new();
    for entry in stored.entries() {
        if live_digest.get(entry.id.as_str()) == Some(&entry.digest.as_str()) {
            kept.insert(entry.id.clone());
        } else {
            removed.push((entry.id.clone(), entry.digest.clone()));
        }
    }
    // Old content for the removed members: a tombstoned drawer still
    // carries its content; an expunged one (zeroed) or one whose digest
    // moved cannot be subtracted exactly, so the container is rescored
    // whole.
    let mut removed_content: BTreeMap<String, String> = BTreeMap::new();
    let mut rescore_whole = whole || roster_data.is_none();
    if !rescore_whole && !removed.is_empty() {
        let ids: Vec<&str> = removed.iter().map(|(id, _)| id.as_str()).collect();
        let olds = estate.get_drawers(&ids).map_err(failure)?;
        let by_id: BTreeMap<String, &locus_kit::drawer::Drawer> = olds.iter().map(|d| (d.id.to_lowercase(), d)).collect();
        for (id, digest) in &removed {
            match by_id.get(id) {
                Some(old) if content_digest(&old.content) == *digest => {
                    removed_content.insert(id.clone(), old.content.clone());
                }
                _ => {
                    rescore_whole = true;
                    break;
                }
            }
        }
    }
    let mut roster = if rescore_whole { CohesionRoster::default() } else { stored };
    if rescore_whole {
        kept.clear();
        removed.clear();
    }

    // The pairwise work: shingle sets once per live member.
    let shingles: BTreeMap<&str, BTreeSet<String>> = live
        .iter()
        .map(|(id, _, content)| (id.as_str(), shingle_similarity::shingles(content)))
        .collect();
    let empty: BTreeSet<String> = BTreeSet::new();
    // Remove: the old content against every entry still in the roster.
    for (id, _) in &removed {
        let old = shingle_similarity::shingles(removed_content.get(id).map(String::as_str).unwrap_or(""));
        let sims: Vec<i32> = roster
            .entries()
            .iter()
            .filter(|e| e.id != *id)
            .map(|e| CohesionRoster::quantise(shingle_similarity::similarity_sets(&old, shingles.get(e.id.as_str()).unwrap_or(&empty))))
            .collect();
        roster.remove(id, &sims);
    }
    // Add: every live member the roster does not hold, in id order.
    for (id, digest, _) in &live {
        if kept.contains(id) {
            continue;
        }
        let mine = shingles.get(id.as_str()).unwrap_or(&empty);
        let sims: Vec<i32> = roster
            .entries()
            .iter()
            .map(|e| CohesionRoster::quantise(shingle_similarity::similarity_sets(mine, shingles.get(e.id.as_str()).unwrap_or(&empty))))
            .collect();
        roster.add(id, digest, &sims);
    }
    let flags: BTreeMap<String, bool> = roster.flags(threshold, ANOMALY_SWEEP_MIN_ROOM_SIZE).into_iter().collect();

    for drawer in &drawers {
        let should = *flags.get(&drawer.id.to_lowercase()).unwrap_or(&false);
        if drawer.is_anomalous() != should {
            changed += estate.set_anomalous_flag(&drawer.id, should, now).map_err(failure)?;
        }
    }
    row.roster = RosterJson::from_roster(&roster);
    row.dirty = false;
    write_roster(checkpoints, roster_data.as_deref(), &row, now)?;
    Ok(changed)
}

// ─── Incremental duty form (§ DUTY_LIFECYCLE) ──────────────────────────────

impl EstateCoordinator {
    /// The containers owed a scoring: fold every audit event since the
    /// cursor into container dirtiness (a write to any drawer dirties its
    /// container; a room's re-bin event dirties every container of that
    /// room), then list the containers that are dirty or have never been
    /// scored, skipping any at or above `chest_placement::CAPACITY` (owed a
    /// re-bin, not a scoring). This is the duty's debt count and its work
    /// list. Twin of Swift `anomalySweepOwedContainers`.
    pub fn anomaly_sweep_owed_containers(
        &self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<Vec<AnomalyContainer>, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?;
        let checkpoints = self.fact_checkpoints(handle)?;
        let stream = stream();

        // 1. Fold new audit events into dirty containers, advancing the cursor.
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
            let parents: Vec<String> = drawers.iter().map(|d| d.parent_node_id.clone()).collect::<BTreeSet<_>>().into_iter().collect();
            let names = estate.resolve_drawer_node_names(&parents).unwrap_or_default();
            for parent in &parents {
                let Some((wing, room)) = names.get(parent) else { continue };
                let container = AnomalyContainer { node_id: parent.clone(), wing: wing.clone(), room: room.clone() };
                mark_container_dirty(&checkpoints, &container, now)?;
            }
            // A re-bin's one event names the room node: every container of
            // that room changed membership.
            let drawer_ids: BTreeSet<String> = drawers.iter().map(|d| d.id.to_lowercase()).collect();
            for event in &events {
                if event.verb != locus_kit::estate_verbs::CHEST_REBIN_VERB {
                    continue;
                }
                let room_id = uuid::Uuid::from_u128(event.row_id.0).hyphenated().to_string();
                if drawer_ids.contains(&room_id) {
                    continue;
                }
                let names = estate.resolve_drawer_node_names(&[room_id.clone()]).unwrap_or_default();
                let Some((wing, room)) = names.get(&room_id) else { continue };
                for (container, _) in containers_of(&estate, wing, room).map_err(failure)? {
                    mark_container_dirty(&checkpoints, &container, now)?;
                }
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

        // 2. Owed = dirty or never scored, and under capacity.
        let mut known: BTreeMap<String, bool> = BTreeMap::new();
        for payload in checkpoints.payloads(&stream).map_err(failure)? {
            if let Ok(row) = serde_json::from_slice::<RosterRow>(&payload) {
                known.insert(row.container, row.dirty);
            }
        }
        let mut owed = Vec::new();
        for entry in estate.room_level_fingerprints().map_err(failure)? {
            for (container, count) in containers_of(&estate, &entry.wing, &entry.room).map_err(failure)? {
                if count >= chest_placement::CAPACITY {
                    continue;
                }
                if *known.get(&container.node_id.to_lowercase()).unwrap_or(&true) {
                    owed.push(container);
                }
            }
        }
        Ok(owed)
    }

    /// Mark one container dirty directly — the write-path half of the
    /// incremental sweep, called from `reanchor` for both the container a
    /// drawer left and the one it joined (F4: the outgoing container is
    /// visible only at the call site, before the move, because the row
    /// keeps no prior parent and the audit event's anchors carry the UDC
    /// lattice, not the parent). Twin of Swift `markAnomalySweepContainerDirty`.
    pub(crate) fn mark_anomaly_sweep_container_dirty(
        &self,
        handle: &EstateHandle,
        container: &AnomalyContainer,
        now: i64,
    ) -> Result<(), GeniusLocusKitError> {
        let checkpoints = self.fact_checkpoints(handle)?;
        mark_container_dirty(&checkpoints, container, now)
    }

    /// Score up to `limit` owed containers and mark them clean. Returns the
    /// containers scored; the duty queue carries the remainder forward. Twin
    /// of Swift `runAnomalySweepBatch`.
    ///
    /// Three phases so the resident can run the scoring OUTSIDE the
    /// coordinator mutex: `anomaly_sweep_prepare` (needs the coordinator),
    /// `anomaly_sweep_score` (a free function over a cloned `Estate`, no
    /// coordinator), `anomaly_sweep_settle` (needs the coordinator). This
    /// inline form runs all three under whatever lock the caller holds; it is
    /// what `mootx01 drain` and `dream` use, where nothing else is waiting.
    pub fn run_anomaly_sweep_batch(
        &self,
        handle: &EstateHandle,
        limit: usize,
        now: i64,
    ) -> Result<usize, GeniusLocusKitError> {
        let work = self.anomaly_sweep_prepare(handle, limit, now)?;
        let scored = anomaly_sweep_score(&work, now)?;
        self.anomaly_sweep_settle(handle, &scored, now)
    }

    /// Phase 1 of the anomaly sweep batch: the containers owed a scoring,
    /// capped at `limit`, with a clone of the estate and the checkpoint
    /// store to score them against. Cheap under the coordinator lock: the
    /// audit fold in `anomaly_sweep_owed_containers` is bounded, and
    /// `Estate` is an `Arc` bundle, so the clone shares the store.
    pub fn anomaly_sweep_prepare(
        &self,
        handle: &EstateHandle,
        limit: usize,
        now: i64,
    ) -> Result<AnomalySweepWork, GeniusLocusKitError> {
        let estate = self.estate_for_verb(handle).map_err(failure)?.clone();
        let checkpoints = self.fact_checkpoints(handle)?;
        let containers = self.anomaly_sweep_owed_containers(handle, now)?.into_iter().take(limit).collect();
        Ok(AnomalySweepWork { estate, checkpoints, containers })
    }

    /// Phase 3 of the anomaly sweep batch: the scored containers were
    /// written clean by the scoring itself (the roster row carries the
    /// dirty mark), so settle only counts them. Kept as a phase so the
    /// resident's lock discipline reads the same on both ports.
    pub fn anomaly_sweep_settle(
        &self,
        _handle: &EstateHandle,
        scored: &[AnomalyContainer],
        _now: i64,
    ) -> Result<usize, GeniusLocusKitError> {
        Ok(scored.len())
    }
}

/// One anomaly sweep batch between `anomaly_sweep_prepare` and
/// `anomaly_sweep_settle`: the containers to score, the estate to score
/// them in, and the checkpoint store the rosters live in. Carries no
/// coordinator borrow, so it can leave the coordinator lock.
pub struct AnomalySweepWork {
    pub estate: Estate,
    pub checkpoints: QueueCheckpointStore,
    pub containers: Vec<AnomalyContainer>,
}

/// Phase 2 of the anomaly sweep batch: score every container in `work`.
/// Runs with NO coordinator lock held. A first scoring is O(n²) in the
/// container's size (at most 250 000 pairs); every later pass is linear in
/// the drawers that changed. Returns the containers scored, in order; a
/// scoring error stops the batch and is returned, and the containers
/// already scored are clean (their rows are written by the scoring).
pub fn anomaly_sweep_score(
    work: &AnomalySweepWork,
    now: i64,
) -> Result<Vec<AnomalyContainer>, GeniusLocusKitError> {
    let mut scored = Vec::with_capacity(work.containers.len());
    for container in &work.containers {
        score_container(&work.estate, &work.checkpoints, container, ANOMALY_SWEEP_DEFAULT_THRESHOLD, false, now)?;
        scored.push(container.clone());
    }
    Ok(scored)
}

/// Parent node id (a room or a chest) → (wing, room) through the estate's
/// node store; drawers whose room cannot be resolved are skipped (an
/// estate opened without a node tree). `pub(crate)` so
/// `coordinator::reanchor` can resolve a drawer's pre-move container
/// before calling `Estate::reanchor` (F4).
pub(crate) fn resolve_room_names<'a>(
    estate: &Estate,
    parent_ids: impl Iterator<Item = &'a str>,
) -> BTreeMap<String, (String, String)> {
    let ids: Vec<String> = parent_ids.map(str::to_string).collect::<BTreeSet<_>>().into_iter().collect();
    estate.resolve_drawer_node_names(&ids).unwrap_or_default()
}
