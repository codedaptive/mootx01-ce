//! Standing signal 7 (end-of-day-tournament): folds the day's recall traces
//! into per-drawer Bradley-Terry ratings stored in `recall_ratings`.
//!
//! Mirrors Swift `Brain/EndOfDayTournament.swift`. The grouping and the fold
//! are pure functions over the trace window and the stored ratings; the
//! estate read/write glue is `EstateCoordinator::end_of_day_tournament`
//! (coordinator.rs).

use std::collections::{BTreeMap, HashMap};

use locus_kit::recall_rating::RecallRating;
use locus_kit::recall_trace_item::RecallTraceItem;
use substrate_ml::bradley_terry::{BradleyTerryEstimator, PreferenceObservation, RowId};
use uuid::Uuid;

/// Outcome of one end-of-day tournament pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TournamentReport {
    /// Number of preference observations fed to the estimator (one per
    /// minute group with two or more distinct UUID targets).
    pub contests: usize,

    /// Number of `recall_ratings` rows written by this pass.
    pub rated_drawers: usize,
}

/// Length of the tournament window in seconds: every trace with
/// `recalled_at` in `[now - 24h, now]` takes part. Daily cadence matches the
/// signal's spec.
pub const TOURNAMENT_WINDOW_SECONDS: i64 = 24 * 60 * 60;

/// Estimator learning rate — cookbook §8.12.3 default, the value the Swift
/// twin's `BradleyTerryEstimator(theta:)` initialiser carries.
const LEARNING_RATE: f64 = 0.05;

/// Estimator L2 coefficient — cookbook §8.12.3 default, matching the Swift twin.
const L2: f64 = 0.001;

/// The contests of one tournament window.
#[derive(Debug, Clone)]
pub struct TournamentContests {
    /// One observation per minute group with two or more distinct UUID
    /// targets: the first-listed drawer beats the rest.
    pub observations: Vec<PreferenceObservation>,

    /// Number of observations each participant took part in, keyed by the
    /// drawer's UUID (ascending order, so the written rows are deterministic).
    pub appearances: BTreeMap<Uuid, usize>,
}

/// Estimator row id for a drawer UUID: the same 128-bit identity Swift uses
/// through `RowId = UUID`.
fn row_id(id: Uuid) -> RowId {
    RowId(id.as_u128())
}

/// Contest bucket key: the ISO8601 string truncated to the minute
/// (`YYYY-MM-DDTHH:MM`). Trace rows carry canonical UTC ISO8601, so this
/// prefix names the same bucket as the Swift twin's
/// `floor(timeIntervalSince1970 / 60)`. A string too short to carry a minute
/// is its own bucket.
fn minute_bucket(recalled_at: &str) -> &str {
    recalled_at.get(..16).unwrap_or(recalled_at)
}

/// Group the window's traces into contests: traces are bucketed by minute of
/// `recalled_at` in the store's ascending order, so the first-listed drawer
/// of a bucket is the earliest trace of that minute; targets are
/// de-duplicated within a bucket; targets that are not UUID strings cannot
/// be estimator row ids and are skipped; a bucket with fewer than two
/// targets produces no observation.
pub fn group_contests(traces: &[RecallTraceItem]) -> TournamentContests {
    let mut bucket_order: Vec<&str> = Vec::new();
    let mut buckets: HashMap<&str, Vec<Uuid>> = HashMap::new();
    for trace in traces {
        let id = match Uuid::parse_str(&trace.target) {
            Ok(id) => id,
            Err(_) => continue,
        };
        let bucket = minute_bucket(&trace.recalled_at);
        let ids = buckets.entry(bucket).or_insert_with(|| {
            bucket_order.push(bucket);
            Vec::new()
        });
        if !ids.contains(&id) {
            ids.push(id);
        }
    }

    let mut observations = Vec::new();
    let mut appearances: BTreeMap<Uuid, usize> = BTreeMap::new();
    for bucket in bucket_order {
        let ids = &buckets[bucket];
        if ids.len() < 2 {
            continue;
        }
        observations.push(PreferenceObservation::new(
            row_id(ids[0]),
            ids[1..].iter().map(|id| row_id(*id)).collect(),
        ));
        for id in ids {
            *appearances.entry(*id).or_insert(0) += 1;
        }
    }
    TournamentContests { observations, appearances }
}

/// Fold the contests into one rating per participant. The estimator is
/// seeded from the stored ratings so strengths accumulate across passes
/// (unseen drawers start at the estimator's zero prior — the stored
/// `rating` seeds `theta` directly, as the Swift twin does); a drawer's
/// stored `contests` count is carried forward and incremented by the number
/// of observations it took part in. `now_iso` stamps `updated_at`. Rows come
/// back in ascending drawer-id order.
pub fn fold_ratings(
    contests: &TournamentContests,
    stored: &[RecallRating],
    now_iso: &str,
) -> Vec<RecallRating> {
    let stored_by_id: HashMap<&str, &RecallRating> = stored
        .iter()
        .map(|rating| (rating.drawer_id.as_str(), rating))
        .collect();

    let mut estimator = BradleyTerryEstimator::new(LEARNING_RATE, L2);
    for id in contests.appearances.keys() {
        if let Some(prior) = stored_by_id.get(id.to_string().as_str()) {
            estimator.theta.insert(row_id(*id), prior.rating);
        }
    }
    estimator.observe_batch(&contests.observations);

    contests
        .appearances
        .iter()
        .map(|(id, appeared)| {
            let key = id.to_string();
            let prior_contests = stored_by_id
                .get(key.as_str())
                .map(|rating| rating.contests)
                .unwrap_or(0);
            RecallRating::new(
                key,
                estimator.strength(row_id(*id)),
                prior_contests + *appeared as i64,
                now_iso,
            )
        })
        .collect()
}
