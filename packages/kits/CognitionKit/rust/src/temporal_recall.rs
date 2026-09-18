//! TemporalRecall — the query-date window recipe. Rust parity of the Swift
//! `CognitionKit/TemporalRecall.swift`; see that file and the decision record
//! (DECISION_SEARCH_STRATEGY_RECIPES_2026-08-19, item 4) for the design.
//!
//! Ascent (pure sequencing; parse and window math live in
//! neuron_kit::query_date_window):
//!   a. WINDOW RESOLUTION: explicit from/to args win; else parse the query;
//!      month-only expands against the coarse pool's own event-time years.
//!   b. GLK FETCH: the same coarse high-recall grab as precise_recall (.full
//!      hydration in this port — one round-trip; selection is body-free).
//!   b'. DATED GRAB (grab = Dated, ruling Q1): a second fetch BY DATE
//!      (EventAfter/EventBefore over the max-padded windows) unioned into
//!      the pool, so date-matched evidence no text lane surfaces still
//!      becomes a candidate.
//!   c. WINDOW APPLICATION with SLIDING EXPANSION (ruling Q2): the window
//!      widens ±1 day at a time while members < limit, hard cap ±10; each
//!      member carries its pad distance.
//!   c''. WITHIN-WINDOW RE-RANK (ruling Q3): members are affinity-folded by
//!      the same composition machinery precise_recall uses, then ordered
//!      pad-first (date proximity primary, affinity secondary). Bounded by
//!      RERANK_CAP; overflow keeps coarse order after the folded block.
//!   d. Survivor bodies from the pre-fetched map (late-hydration parity).
//! Read-only, deterministic (no clock in the ranking path; `now` is the
//! coordinator telemetry parameter shared by every recipe).

use std::collections::HashMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
use neuron_kit::query_date_window::{
    expand_month_only, padded_window, parse_query_date_expression, window_contains,
    QueryDateParse, QueryDateWindow,
};
use neuron_kit::{
    named_composition, reduce_late, ReductionCandidate, ReductionQuery,
    DEFAULT_SURVIVOR_MULTIPLE,
};

use crate::error::{RecipeRunError, SubstrateError};

/// Default coarse pool. Wider than precise_recall's 30: the window is the
/// discriminator, so the grab errs toward recall. Mirrors Swift
/// `TemporalRecall.defaultPool`.
pub const TEMPORAL_DEFAULT_POOL: usize = 120;

/// Sliding-window hard cap (ruling Q2): the window may widen ±1 day at a
/// time while members < limit, never beyond ±10 days. Mirrors Swift
/// `TemporalRecall.maxPadDays`.
pub const TEMPORAL_MAX_PAD_DAYS: i64 = 10;

/// Member re-rank ceiling (Swift `TemporalRecall.rerankCap`): at most this
/// many in-window members are affinity-folded; overflow keeps coarse order
/// after the folded block, within its pad tier.
pub const TEMPORAL_RERANK_CAP: usize = 200;

/// Window mode. Mirrors Swift `TemporalWindowMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemporalWindowMode {
    /// Boost: in-window candidates rank first, everything retained.
    Loose,
    /// Hard filter: in-window candidates only.
    Tight,
}

impl TemporalWindowMode {
    pub fn parse(s: Option<&str>) -> Result<Self, String> {
        match s.unwrap_or("loose") {
            "loose" => Ok(Self::Loose),
            "tight" => Ok(Self::Tight),
            other => Err(format!("window must be 'loose' or 'tight'; got '{other}'")),
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Loose => "loose",
            Self::Tight => "tight",
        }
    }
}

/// Candidate-grab arm (ruling Q1 2026-08-19: build BOTH and compare).
/// Mirrors Swift `TemporalGrab`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemporalGrab {
    /// Lexical coarse grab only (v1 behavior).
    Pool,
    /// Lexical grab UNIONED with a date-indexed store fetch.
    Dated,
}

impl TemporalGrab {
    pub fn parse(s: Option<&str>) -> Result<Self, String> {
        match s.unwrap_or("pool") {
            "pool" => Ok(Self::Pool),
            "dated" => Ok(Self::Dated),
            other => Err(format!("grab must be 'pool' or 'dated'; got '{other}'")),
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pool => "pool",
            Self::Dated => "dated",
        }
    }
}

/// One temporal-recall match. Mirrors Swift `TemporalMatch`.
#[derive(Debug, Clone, PartialEq)]
pub struct TemporalMatch {
    pub id: String,
    pub room: String,
    pub content: String,
    /// UTC ISO8601 event time, None when the drawer carried none.
    pub event_time: Option<String>,
    pub in_window: bool,
    /// Sliding-window distance: 0 = inside the stated window; n = inside
    /// only after widening by ±n days; None = outside every padded window
    /// (loose-mode tail rows only).
    pub pad_days: Option<i64>,
}

/// The recipe's outcome. Mirrors Swift `TemporalRecallOutcome`.
#[derive(Debug, Clone)]
pub struct TemporalRecallOutcome {
    pub matches: Vec<TemporalMatch>,
    pub windows: Vec<QueryDateWindow>,
    /// "explicit" | "parsed" | "none".
    pub window_source: String,
    pub mode: TemporalWindowMode,
    /// The grab arm that supplied the candidates.
    pub grab: TemporalGrab,
    /// The sliding-window pad (days) at which the member quorum was met;
    /// 0 = the stated window sufficed. Meaningless when `windows` is empty.
    pub applied_pad: i64,
}

/// Converts epoch milliseconds (the Rust port's event-time convention) to
/// the fixed UTC ISO8601 second shape. Civil-from-days (Hinnant) — pure
/// integer math, deterministic, matches the Swift UTC calendar rendering.
pub fn epoch_ms_to_iso(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    // civil_from_days
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    format!(
        "{year:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        sod / 3600, (sod % 3600) / 60, sod % 60
    )
}

/// Inverse of `epoch_ms_to_iso` for the fixed "YYYY-MM-DDTHH:MM:SSZ" bound
/// shape (days-from-civil, Hinnant). Feeds the EventAfter/EventBefore filter
/// bounds of the dated grab. Malformed input returns None — the caller
/// treats that window filter as absent rather than fabricating an epoch.
pub fn iso_to_epoch_ms(iso: &str) -> Option<i64> {
    if iso.len() != 20 || !iso.ends_with('Z') {
        return None;
    }
    let y: i64 = iso[0..4].parse().ok()?;
    let m: i64 = iso[5..7].parse().ok()?;
    let d: i64 = iso[8..10].parse().ok()?;
    let hh: i64 = iso[11..13].parse().ok()?;
    let mm: i64 = iso[14..16].parse().ok()?;
    let ss: i64 = iso[17..19].parse().ok()?;
    // days_from_civil (Hinnant)
    let yy = if m <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 86_400) + hh * 3600 + mm * 60 + ss) * 1000)
}

fn explicit_bound(raw: &str, is_from: bool) -> Result<String, String> {
    // Strict shape validation (codex finding 2026-08-26): the previous
    // checks (length + one delimiter/suffix byte) accepted arbitrary bytes
    // in the digit positions — including multibyte characters, which later
    // panicked the fixed narration slice `&w.start[0..10]` on a non-UTF-8
    // boundary. Every byte position is verified against the template, so
    // accepted bounds are all-ASCII by construction and the fixed slices
    // downstream are safe. Twin of Swift `TemporalRecall.explicitBound`.
    fn matches_shape(s: &str, shape: &[u8]) -> bool {
        s.len() == shape.len()
            && s.bytes().zip(shape.iter()).all(|(c, &t)| {
                if t == b'9' { c.is_ascii_digit() } else { c == t }
            })
    }
    if matches_shape(raw, b"9999-99-99") {
        return Ok(format!(
            "{raw}{}", if is_from { "T00:00:00Z" } else { "T23:59:59Z" }));
    }
    if matches_shape(raw, b"9999-99-99T99:99:99Z") {
        return Ok(raw.to_string());
    }
    Err(format!(
        "temporal_recall: from/to must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ; got '{raw}'"))
}

/// Runs temporal recall. Mirrors Swift `TemporalRecall.run`; tight mode
/// without a resolvable window is caller misuse and errors loud.
#[allow(clippy::too_many_arguments)]
pub fn run(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    filter: Filter,
    limit: usize,
    pool: usize,
    mode: TemporalWindowMode,
    grab: TemporalGrab,
    from: Option<&str>,
    to: Option<&str>,
    now: i64,
    node_names: &HashMap<String, (String, String)>,
) -> Result<TemporalRecallOutcome, RecipeRunError> {
    let pool_size = pool.max(limit);

    // b. GLK FETCH — twin of precise_recall's grab (.full: one round-trip,
    //    body map backs late hydration; selection below is body-free).
    let fetch = |fetch_filter: Filter| -> Result<_, RecipeRunError> {
        let frame = RecallFrame {
            filter_chain: vec![fetch_filter],
            hydration_level: HydrationLevel::Full,
            limit: Some(pool_size),
            ordering: Ordering::ByCaptureTimeDesc,
            as_of: None,
            trace_limit: Some(limit),
        };
        let request = GLKRecallRequest {
            frame,
            mode: GLKRecallMode::UnionBest,
            scoring: GLKRecallScoring::Raw,
            limit: pool_size,
            fallback: RecallFallbackPolicy::AllowDegraded,
            query_text: Some(query.to_string()),
            trace_limit: Some(limit),
            origin: genius_locus_kit::recall::RecallOrigin::Internal,
            recall_shape: None,
            // W2.5 Track R(a): recipes are internal-origin — no trace rows are
            // written, so door/composition stay None.
            door: None,
            composition: None,
            frontier_k: None,
            // §11.18: internal recall — no anomalous-flag filter applied.
            anomalous_filter: None,
            chest_diversity: None,
            // Sub-span scoring is an additive-cost stage this recipe does not
            // request; every caller names the switch (ruling 2026-09-07).
            sub_span_scoring: genius_locus_kit::recall::GLKSubSpanScoring::Off,
            rerank_directive: None,
        };
        coord
            .recall_scored(handle, request, now)
            .map_err(|e| SubstrateError::new("recall", format!("{e:?}")).into())
    };
    let result = fetch(filter.clone())?;

    let mut body_map: HashMap<String, String> = HashMap::new();
    let mut strip = |mut candidate: ReductionCandidate| -> ReductionCandidate {
        if !candidate.content.is_empty() {
            body_map.insert(candidate.id.clone(), candidate.content.clone());
            candidate.content = String::new();
        }
        candidate
    };
    let mut candidates: Vec<ReductionCandidate> = result
        .hits
        .iter()
        .enumerate()
        .map(|(index, hit)| strip(ReductionCandidate::from_hit(hit, index, node_names)))
        .collect();

    // M4 single-derivation: extract the pre-computed §8.3 lattice anchor from
    // the GLK result. The director derived it once in recall_scored_multi_lane;
    // callers MUST NOT call query_anchor separately on the same text.
    // Save it now while result is still live (it is only borrowed for hits above).
    let result_lattice_anchor = result.query_lattice_anchor.clone();

    // a. WINDOW RESOLUTION — explicit wins; month-only expands against the
    //    pool's own event-time years.
    let mut windows: Vec<QueryDateWindow> = Vec::new();
    let mut source = "none";
    if from.is_some() || to.is_some() {
        let start = match from {
            Some(f) => explicit_bound(f, true)
                .map_err(|e| SubstrateError::new("temporal_recall", e))?,
            None => "0000-01-01T00:00:00Z".to_string(),
        };
        let end = match to {
            Some(t) => explicit_bound(t, false)
                .map_err(|e| SubstrateError::new("temporal_recall", e))?,
            None => "9999-12-31T23:59:59Z".to_string(),
        };
        windows.push(QueryDateWindow { start, end, matched_text: "explicit".into() });
        source = "explicit";
    } else {
        match parse_query_date_expression(query) {
            QueryDateParse::Anchored(w) => {
                windows = w;
                source = "parsed";
            }
            QueryDateParse::MonthOnly { month, matched_text } => {
                let years: Vec<i32> = candidates
                    .iter()
                    .filter_map(|c| c.event_time)
                    .map(|ms| epoch_ms_to_iso(ms)[0..4].parse::<i32>().unwrap())
                    .collect();
                if let (Some(&lo), Some(&hi)) = (years.iter().min(), years.iter().max()) {
                    windows = expand_month_only(month, &matched_text, lo..=hi);
                    source = "parsed";
                }
            }
            QueryDateParse::None => {}
        }
    }
    // Gap 3 scanner fork: the query ASKS FOR a date but states none. No
    // window can apply — the date is the ANSWER — so loose mode ranks
    // REAL-dated memories (event_time != filed_at) first and the caller
    // reads the date off the returned rows' event_time.
    let date_seeking = windows.is_empty()
        && neuron_kit::query_date_window::is_date_seeking_query(query);
    if date_seeking {
        source = "date-seeking";
    }
    if windows.is_empty() && mode == TemporalWindowMode::Tight {
        return Err(SubstrateError::new(
            "temporal_recall",
            "window \"tight\" requires a date — none was parsed from the query \
             and no from/to was supplied".to_string(),
        )
        .into());
    }

    // b'. DATED GRAB (ruling Q1) — union a date-indexed fetch into the pool.
    //     Windows are pre-padded to the ±10 cap so the sliding expansion
    //     below has material.
    if grab == TemporalGrab::Dated && !windows.is_empty() {
        let window_filters: Vec<Filter> = windows
            .iter()
            .filter_map(|w| {
                let padded = padded_window(w, TEMPORAL_MAX_PAD_DAYS);
                match (iso_to_epoch_ms(&padded.start), iso_to_epoch_ms(&padded.end)) {
                    (Some(s), Some(e)) => Some(Filter::All(vec![
                        Filter::EventAfter(s),
                        Filter::EventBefore(e),
                    ])),
                    _ => None,
                }
            })
            .collect();
        if !window_filters.is_empty() {
            let dated = fetch(Filter::All(vec![
                filter.clone(),
                Filter::Any(window_filters),
            ]))?;
            let seen: std::collections::HashSet<String> =
                candidates.iter().map(|c| c.id.clone()).collect();
            let base = candidates.len();
            for (index, hit) in dated.hits.iter().enumerate() {
                if seen.contains(&hit.id) {
                    continue;
                }
                // Dated-only candidates rank after the lexical pool: the
                // affinity fold, not arrival order, decides their place.
                candidates.push(strip(ReductionCandidate::from_hit(
                    hit, base + index, node_names)));
            }
        }
    }

    // c. WINDOW APPLICATION with SLIDING EXPANSION (ruling Q2) — pad_days(c)
    //    is the smallest pad at which the candidate falls inside some
    //    window; the applied pad is the smallest one whose member count
    //    reaches `limit` (or the cap if none does).
    let pad_days_of = |c: &ReductionCandidate| -> Option<i64> {
        let ms = c.event_time?;
        if windows.is_empty() {
            return None;
        }
        let iso = epoch_ms_to_iso(ms);
        (0..=TEMPORAL_MAX_PAD_DAYS).find(|&pad| {
            windows.iter().any(|w| window_contains(&padded_window(w, pad), &iso))
        })
    };
    // Date-seeking membership: a candidate is a member when it carries a
    // REAL event date (event_time present and != filed_at); pad 0. The
    // ordinary path computes sliding-window pads.
    let flagged: Vec<(ReductionCandidate, Option<i64>)> = candidates
        .iter()
        .map(|c| {
            let pad = if date_seeking {
                match (c.event_time, c.filed_at) {
                    (Some(e), Some(f)) if e != f => Some(0),
                    _ => None,
                }
            } else {
                pad_days_of(c)
            };
            (c.clone(), pad)
        })
        .collect();
    let mut applied_pad: i64 = 0;
    if !windows.is_empty() {
        while applied_pad < TEMPORAL_MAX_PAD_DAYS
            && flagged.iter().filter(|(_, p)| p.map_or(false, |p| p <= applied_pad)).count()
                < limit
        {
            applied_pad += 1;
        }
    }
    let members: Vec<(ReductionCandidate, i64)> = flagged
        .iter()
        .filter_map(|(c, p)| p.filter(|p| *p <= applied_pad).map(|p| (c.clone(), p)))
        .collect();
    let outsiders: Vec<(ReductionCandidate, Option<i64>)> = flagged
        .into_iter()
        .filter(|(_, p)| p.map_or(true, |p| p > applied_pad))
        .collect();

    // c''. WITHIN-WINDOW RE-RANK (ruling Q3) — pad-first over the affinity
    //     fold, bounded by TEMPORAL_RERANK_CAP; overflow keeps coarse order.
    let mut preselected = members;
    preselected.sort_by_key(|(c, p)| (*p, c.coarse_rank));
    let overflow: Vec<(ReductionCandidate, i64)> =
        preselected.split_off(preselected.len().min(TEMPORAL_RERANK_CAP));
    let fold_set = preselected;
    let pad_by_id: HashMap<String, i64> =
        fold_set.iter().map(|(c, p)| (c.id.clone(), *p)).collect();
    let comp = named_composition(None);
    // Query-side §8.3 lattice anchor (W2.5 Track S): lets lattice-bearing
    // compositions fire; the default text composition never reads it.
    //
    // M4 single-derivation: read the pre-computed anchor extracted from the
    // GLK result above. The director derived it exactly once in
    // recall_scored_multi_lane; calling query_anchor here again on the same
    // query text would violate the single-derivation doctrine.
    // When the query was unanchorable, result_lattice_anchor is None and both
    // fields default to "" (lattice signal stays neutral, same as before M4).
    let mut reduction_query = ReductionQuery::new(query);
    reduction_query.udc_code = result_lattice_anchor
        .as_ref().map(|(udc, _)| udc.clone()).unwrap_or_default();
    reduction_query.qid = result_lattice_anchor
        .as_ref().map(|(_, qid)| qid.clone()).unwrap_or_default();
    let fold_candidates: Vec<ReductionCandidate> =
        fold_set.iter().map(|(c, _)| c.clone()).collect();
    let fold_limit = fold_candidates.len();
    let folded = reduce_late(
        &comp,
        &reduction_query,
        &fold_candidates,
        fold_limit,
        DEFAULT_SURVIVOR_MULTIPLE,
        |ids| {
            let mut out = HashMap::new();
            for id in ids {
                if let Some(body) = body_map.get(id) {
                    out.insert(id.clone(), body.clone());
                }
            }
            out
        },
    );
    // Pad-first over the affinity order: enumerate the fold order so the
    // sort is explicitly stable on (pad, affinity index).
    let mut folded_with_keys: Vec<(i64, usize, ReductionCandidate)> = folded
        .into_iter()
        .enumerate()
        .map(|(index, c)| {
            let pad = pad_by_id.get(&c.id).copied().unwrap_or(0);
            (pad, index, c)
        })
        .collect();
    folded_with_keys.sort_by_key(|(pad, index, _)| (*pad, *index));
    let mut ranked_members: Vec<(ReductionCandidate, i64)> = folded_with_keys
        .into_iter()
        .map(|(pad, _, c)| (c, pad))
        .collect();
    ranked_members.extend(overflow);

    // Final ordering. Loose keeps everything: members first, then the
    // outsiders in coarse order (v1 semantics, now pad-aware). Tight
    // returns members only.
    let survivors: Vec<(ReductionCandidate, Option<i64>)> = match mode {
        TemporalWindowMode::Loose => ranked_members
            .into_iter()
            .map(|(c, p)| (c, Some(p)))
            .chain(outsiders)
            .take(limit)
            .collect(),
        TemporalWindowMode::Tight => ranked_members
            .into_iter()
            .map(|(c, p)| (c, Some(p)))
            .take(limit)
            .collect(),
    };

    // d. Survivor bodies from the pre-fetched map (the fold hydrated its own
    //    survivors; outsiders and overflow read the map here).
    let matches = survivors
        .into_iter()
        .map(|(c, pad)| TemporalMatch {
            id: c.id.clone(),
            room: c.room.clone(),
            content: if c.content.is_empty() {
                body_map.get(&c.id).cloned().unwrap_or_default()
            } else {
                c.content.clone()
            },
            event_time: c.event_time.map(epoch_ms_to_iso),
            in_window: pad.is_some(),
            pad_days: pad,
        })
        .collect();

    let applied_pad = if windows.is_empty() { 0 } else { applied_pad };
    Ok(TemporalRecallOutcome {
        matches,
        windows,
        window_source: source.to_string(),
        mode,
        grab,
        applied_pad,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_ms_to_iso_pins() {
        // 2023-07-17T14:31:00Z
        assert_eq!(epoch_ms_to_iso(1_689_604_260_000), "2023-07-17T14:31:00Z");
        assert_eq!(epoch_ms_to_iso(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn iso_to_epoch_ms_roundtrip() {
        assert_eq!(iso_to_epoch_ms("2023-07-17T14:31:00Z"), Some(1_689_604_260_000));
        assert_eq!(iso_to_epoch_ms("1970-01-01T00:00:00Z"), Some(0));
        for pin in ["2023-05-08T00:00:00Z", "2024-02-29T23:59:59Z", "2026-08-19T19:01:42Z"] {
            assert_eq!(epoch_ms_to_iso(iso_to_epoch_ms(pin).unwrap()), pin);
        }
        assert_eq!(iso_to_epoch_ms("May 2023"), None);
    }

    #[test]
    fn explicit_bounds() {
        assert_eq!(explicit_bound("2023-05-08", true).unwrap(), "2023-05-08T00:00:00Z");
        assert_eq!(explicit_bound("2023-05-08", false).unwrap(), "2023-05-08T23:59:59Z");
        assert!(explicit_bound("May 2023", true).is_err());
    }

    #[test]
    fn grab_and_mode_parse() {
        assert_eq!(TemporalGrab::parse(None).unwrap(), TemporalGrab::Pool);
        assert_eq!(TemporalGrab::parse(Some("dated")).unwrap(), TemporalGrab::Dated);
        assert!(TemporalGrab::parse(Some("union")).is_err());
        assert_eq!(TemporalWindowMode::parse(Some("tight")).unwrap(), TemporalWindowMode::Tight);
    }

    /// codex 2026-08-26: non-digit bytes in digit positions must be
    /// rejected, never accepted into the window (the old length+suffix
    /// check let "2023-aa-bb" and multibyte 20-byte values through, the
    /// latter panicking the narration's fixed byte slice).
    #[test]
    fn explicit_bound_rejects_non_digit_shapes() {
        assert!(explicit_bound("2023-aa-bb", true).is_err());
        assert!(explicit_bound("2023-01-0é", true).is_err());
        // 20 bytes ending in Z with an embedded multibyte char: the exact
        // panic shape from the finding.
        assert!(explicit_bound("123456789é12345678Z", true).is_err());
        assert!(explicit_bound("9999-99-99T99:99:9Z", true).is_err());
    }

    #[test]
    fn explicit_bound_accepts_strict_shapes() {
        assert_eq!(
            explicit_bound("2023-04-01", true).unwrap(),
            "2023-04-01T00:00:00Z");
        assert_eq!(
            explicit_bound("2023-04-01T12:30:00Z", false).unwrap(),
            "2023-04-01T12:30:00Z");
    }
}
