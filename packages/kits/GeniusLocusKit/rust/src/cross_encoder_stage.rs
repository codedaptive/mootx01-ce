//! The retrieval-time cross-encoder stage. Twin of Swift
//! `RecallDirector/CrossEncoderStage.swift`.
//!
//! After every lane, fusion and the §11.18 admission gate have produced the
//! authorized final list, a pair classifier scores (query, span) pairs for the
//! HEAD of that list, takes the best logit per candidate, and fuses the cross
//! order back into the incoming order with reciprocal-rank fusion. The tail
//! beyond the head is never touched; membership never changes. The stage runs
//! only when the request carries `RerankDirective { action: Apply }`; an
//! absent directive is bypass.
//!
//! An apply with a packaged profile widens the lanes' presentation cut to the
//! stage's pool before they run (the coordinator raises the lane request's
//! limit; frontier_k is unchanged). The incoming order the stage sees, and
//! the order a degraded apply hands back, is therefore the head of that
//! pool-wide page, re-cut to the caller's limit. A bypass or an unknown
//! profile never widens and is byte-identical to a request without a
//! directive.
//!
//! This module holds the pure parts (the fusion rule, the span selection and
//! the report) so the shared parity fixture
//! (`SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json`) exercises
//! exactly the code the coordinator runs. The lifecycle (lazy scorer load,
//! the manifest limits) and the insertion into `recall_scored` live in
//! coordinator.rs.

use std::collections::{HashMap, HashSet};

use corpus_kit::encoder::{spanner, CrossEncoderProfile, RerankDirective};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::ContentKind;

use crate::recall::RecallHit;
use crate::span_rerank::{dot_query, StrictSpanRerankVector, SpanRerankVector};

/// Evidence carried only for the transcript operation.  Generic rerank
/// reports retain their existing compact shape and best-effort semantics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StrictTranscriptEvidence {
    pub available: bool,
    pub reason: Option<String>,
    pub active_model_id: Option<String>,
    pub active_model_version: Option<String>,
    pub query_dimension: Option<usize>,
    pub fresh_head_candidates: usize,
    pub scored_head_candidates: usize,
    /// Classifier receipt, deliberately distinct from the active Arctic
    /// encoder row above.
    pub classifier_profile_id: Option<String>,
    pub classifier_model_revision: Option<String>,
    /// Fixed recipe values captured after strict validation, not supplied by
    /// an ARIA projection default.
    pub validated_pool_limit: Option<usize>,
    pub validated_head_limit: Option<usize>,
    pub validated_spans_limit: Option<usize>,
    pub validated_rrf_k: Option<usize>,
    /// Serving-generation receipt from the strict Synapse snapshot.
    pub serving_generation: Option<i64>,
    /// Every scored-head member was validated against its FNV content version.
    pub freshness_verified: bool,
}

impl StrictTranscriptEvidence {
    pub fn unavailable(reason: &str) -> Self {
        Self {
            available: false,
            reason: Some(reason.to_string()),
            active_model_id: None,
            active_model_version: None,
            query_dimension: None,
            fresh_head_candidates: 0,
            scored_head_candidates: 0,
            classifier_profile_id: None,
            classifier_model_revision: None,
            validated_pool_limit: None,
            validated_head_limit: None,
            validated_spans_limit: None,
            validated_rrf_k: None,
            serving_generation: None,
            freshness_verified: false,
        }
    }
}

/// The three adjustable maxima the stage runs under, resolved from the estate
/// manifest and clamped to the packaged profile (never above it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CrossEncoderLimits {
    /// Candidates handed to the stage from the front of the final list.
    pub pool: usize,
    /// Candidates, from the front of the pool, that are scored.
    pub head: usize,
    /// Spans per scored candidate paired with the query.
    pub spans: usize,
}

impl CrossEncoderLimits {
    /// Build limits with `head` clamped to `pool`.
    pub fn new(pool: usize, head: usize, spans: usize) -> Self {
        Self { pool, head: head.min(pool), spans }
    }

    /// The profile's own maxima.
    pub fn from_profile(profile: &CrossEncoderProfile) -> Self {
        Self::new(profile.pool, profile.head, profile.spans)
    }
}

/// What the stage did for one recall.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrossEncoderStatus {
    /// The scorer ran and the head was fused.
    Applied,
    /// The directive said bypass (or there was nothing to do).
    Bypassed,
    /// `apply` was requested and could not run; `reason` says why and the
    /// incoming order stands. `recall.cross_encoder_degraded` is also on
    /// `degraded_stages`.
    Degraded,
}

impl CrossEncoderStatus {
    /// The Swift `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            CrossEncoderStatus::Applied => "applied",
            CrossEncoderStatus::Bypassed => "bypassed",
            CrossEncoderStatus::Degraded => "degraded",
        }
    }
}

/// What the stage did for one recall. Rides `GLKRecallResult::cross_encoder`;
/// `None` there means the request carried no directive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrossEncoderReport {
    pub status: CrossEncoderStatus,
    /// Whether the directive asked for `apply`.
    pub requested: bool,
    /// The degrade reason (`reason::*`), or for `Bypassed` and `Applied` the
    /// directive's own diagnostic code echoed back.
    pub reason: Option<String>,
    /// The directive's profile id, whether or not it is packaged.
    pub profile_id: String,
    /// `CrossEncoderProfile::model_version` of the profile that ran, when known.
    pub model_version: Option<String>,
    /// `PairScorer::backend` of the scorer that ran (`coreml`, `candle`, …).
    pub backend: Option<String>,
    /// The limits the stage ran under (zero for bypass).
    pub pool: usize,
    pub head: usize,
    pub spans: usize,
    /// Head candidates that received at least one logit.
    pub scored: usize,
    /// Whether this recall loaded the model (first apply on the estate).
    pub cold_load: bool,
    /// Wall-clock milliseconds of the stage (scorer load excluded), when it ran.
    pub stage_millis: Option<u64>,
    /// Present only for an explicit strict transcript request.
    pub strict_transcript: Option<StrictTranscriptEvidence>,
}

impl CrossEncoderReport {
    /// A bypass report for `directive`.
    pub fn bypassed(directive: &RerankDirective) -> Self {
        Self {
            status: CrossEncoderStatus::Bypassed,
            requested: false,
            reason: directive.reason.clone(),
            profile_id: directive.profile_id.clone(),
            model_version: None,
            backend: None,
            pool: 0,
            head: 0,
            spans: 0,
            scored: 0,
            cold_load: false,
            stage_millis: None,
            strict_transcript: None,
        }
    }

    /// A degraded report for an `apply` that could not run.
    pub fn degraded(directive: &RerankDirective, reason: &str, limits: Option<CrossEncoderLimits>) -> Self {
        Self {
            status: CrossEncoderStatus::Degraded,
            requested: true,
            reason: Some(reason.to_string()),
            profile_id: directive.profile_id.clone(),
            model_version: None,
            backend: None,
            pool: limits.map_or(0, |l| l.pool),
            head: limits.map_or(0, |l| l.head),
            spans: limits.map_or(0, |l| l.spans),
            scored: 0,
            cold_load: false,
            stage_millis: None,
            strict_transcript: None,
        }
    }

    /// The one line the ARIA composer prints for this report. Byte-identical
    /// to Swift `CrossEncoderReport.summaryLine`.
    pub fn summary_line(&self) -> String {
        let mut parts = vec![
            format!("cross_encoder: {}", self.status.raw_value()),
            format!("profile={}", self.profile_id),
        ];
        if let Some(reason) = &self.reason {
            parts.push(format!("reason={reason}"));
        }
        if let Some(backend) = &self.backend {
            parts.push(format!("backend={backend}"));
        }
        if self.status == CrossEncoderStatus::Applied {
            parts.push(format!("pool={}", self.pool));
            parts.push(format!("head={}", self.head));
            parts.push(format!("scored={}", self.scored));
            if self.cold_load {
                parts.push("cold_load".to_string());
            }
            if let Some(ms) = self.stage_millis {
                parts.push(format!("ms={ms}"));
            }
        }
        parts.join(" ")
    }
}

/// Degrade reasons (`CrossEncoderReport::reason` on `Degraded`). Byte-identical
/// to Swift `CrossEncoderStage.Reason`.
pub mod reason {
    /// This build carries no cross-encoder runtime (feature `cross-encoder` off).
    pub const CAPABILITY_OFF: &str = "capability_off";
    /// The directive names a profile this build does not package.
    pub const PROFILE_UNKNOWN: &str = "profile_unknown";
    /// No model directory, or the factory refused it; the detail is in the
    /// one stderr line the activation wrote.
    pub const MODEL_UNAVAILABLE: &str = "model_unavailable";
    /// The request carries no query text to pair spans with.
    pub const NO_QUERY_TEXT: &str = "no_query_text";
    /// The scorer failed while scoring; the incoming order stands.
    pub const SCORER_FAILED: &str = "scorer_failed";
    pub const STRICT_SOURCE_UNAVAILABLE: &str = "strict_source_unavailable";
    pub const STRICT_PROFILE_MISMATCH: &str = "strict_profile_mismatch";
    pub const STRICT_QUERY_INVALID: &str = "strict_query_invalid";
    pub const STRICT_TRANSCRIPT_INELIGIBLE: &str = "strict_transcript_ineligible";
    pub const STRICT_SPANS_UNAVAILABLE: &str = "strict_spans_unavailable";
    pub const STRICT_SPANS_STALE: &str = "strict_spans_stale";
    pub const STRICT_PARTIAL_CLASSIFIER: &str = "strict_partial_classifier";
    pub const SERVING_STATE_CHANGED: &str = "serving_state_changed";
}

/// Source-based transcript admission. A declared transcript kind is
/// authoritative; legacy content must be a complete sequence of role turns.
/// Continuation lines belong to the preceding turn, so quoted dialogue and
/// prose-first documents cannot qualify by mentioning role labels later.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptEligibility {
    DeclaredTranscript,
    LegacyRoleTurns,
    NotTranscript,
}

pub fn classify_transcript(drawer: &Drawer) -> TranscriptEligibility {
    if drawer.content_kind() == ContentKind::Transcript {
        return TranscriptEligibility::DeclaredTranscript;
    }
    fn header(line: &str) -> Option<&str> {
        let trimmed = line.trim();
        let (role, body) = trimmed.split_once(':')?;
        matches!(role.trim().to_ascii_lowercase().as_str(),
            "user" | "assistant" | "system" | "human" | "ai" | "speaker" | "agent" | "customer")
            .then_some(body)
    }
    let Some(first) = drawer.content.lines().find(|line| !line.trim().is_empty()) else {
        return TranscriptEligibility::NotTranscript;
    };
    if header(first).is_none() {
        return TranscriptEligibility::NotTranscript;
    }
    let mut turns = 0usize;
    let mut current_turn_has_body = false;
    for line in drawer.content.lines() {
        if let Some(body) = header(line) {
            if turns > 0 && !current_turn_has_body {
                return TranscriptEligibility::NotTranscript;
            }
            turns += 1;
            current_turn_has_body = !body.trim().is_empty();
        } else if turns > 0 && !line.trim().is_empty() {
            current_turn_has_body = true;
        }
    }
    if turns >= 2 && current_turn_has_body {
        TranscriptEligibility::LegacyRoleTurns
    } else {
        TranscriptEligibility::NotTranscript
    }
}

/// Preserve the incoming order while retaining only records eligible for the
/// strict transcript recipe. The coordinator bounds the input to the stage
/// pool before calling this helper.
pub fn strict_transcript_pool(hits: &[RecallHit]) -> Vec<RecallHit> {
    hits.iter()
        .filter(|hit| hit.drawer.as_ref().is_some_and(|drawer| {
            // The current adjective ceiling does not admit capture-sensitive
            // text. Fail closed before a classifier receives any source body.
            matches!((drawer.provenance >> 30) & 0x3f, 0 | 16)
                && classify_transcript(drawer) != TranscriptEligibility::NotTranscript
        }))
        .cloned()
        .collect()
}

/// Rebuild strict source spans from validated stored rows.  Unlike
/// `select_spans`, this never falls back to Spanner and rejects stale,
/// malformed, or dimension-mismatched rows before the classifier sees a pair.
pub fn select_strict_spans(
    content: &str,
    rows: &[StrictSpanRerankVector],
    query: &[f32],
    limit: usize,
    expected_content_version: &str,
) -> Result<Vec<String>, &'static str> {
    if rows.is_empty() || limit == 0 {
        return Err(reason::STRICT_SPANS_UNAVAILABLE);
    }
    let words = spanner::words(content);
    if words.is_empty() {
        return Err(reason::STRICT_SPANS_UNAVAILABLE);
    }
    let mut ranked: Vec<(&StrictSpanRerankVector, f32)> = rows
        .iter()
        .map(|row| {
            if row.content_version != expected_content_version
                || row.vector.int8.len() != query.len()
                || !row.vector.scale.is_finite()
                || row.vector.scale <= 0.0
                || row.vector.start_word >= row.vector.end_word
                || row.vector.end_word > words.len()
            {
                return Err(if row.content_version != expected_content_version { reason::STRICT_SPANS_STALE } else { reason::STRICT_SPANS_UNAVAILABLE });
            }
            Ok((row, dot_query(query, &row.vector.int8, row.vector.scale)))
        })
        .collect::<Result<_, _>>()?;
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.0.vector.index.cmp(&b.0.vector.index)));
    let spans: Vec<String> = ranked
        .iter()
        .take(limit)
        .map(|(row, _)| words[row.vector.start_word..row.vector.end_word].join(" "))
        .collect();
    if spans.is_empty() { Err(reason::STRICT_SPANS_UNAVAILABLE) } else { Ok(spans) }
}

/// The `degraded_stages` entry every degraded apply appends.
pub const DEGRADED_STAGE: &str = "recall.cross_encoder_degraded";

/// Fuse the incoming order with the cross-encoder logits (the lab's `fuse`,
/// reproduced exactly; twin of Swift `CrossEncoderStage.fuse`):
///
/// 1. `head` = the first `head` of `incoming`; the rest is the tail and is
///    returned unchanged after the fused head.
/// 2. Every head candidate with at least one logit takes its MAX logit; the
///    cross order sorts those by logit descending, ties by incoming rank
///    ascending, then id; candidates without a logit follow in incoming
///    order. Cross rank is 1-based over that list.
/// 3. `score(c) = 1/(k + incoming) + 1/(k + cross)`; the head is sorted by
///    score descending, ties by incoming rank, then id.
///
/// `logits` keys outside the head are ignored; a head id absent from `logits`
/// (or with an empty vector) is unscored.
pub fn fuse(incoming: &[String], head: usize, logits: &HashMap<String, Vec<f32>>, rrf_k: usize) -> Vec<String> {
    let head_count = head.min(incoming.len());
    let head_ids = &incoming[..head_count];
    let tail = &incoming[head_count..];
    if head_ids.is_empty() {
        return incoming.to_vec();
    }
    let mut incoming_rank: HashMap<&str, usize> = HashMap::new();
    for (index, id) in head_ids.iter().enumerate() {
        incoming_rank.entry(id.as_str()).or_insert(index + 1);
    }
    let mut maxima: Vec<(&str, f32)> = Vec::new();
    let mut unscored: Vec<&str> = Vec::new();
    for id in head_ids {
        let best = logits
            .get(id)
            .and_then(|values| values.iter().copied().reduce(f32::max));
        match best {
            Some(logit) => maxima.push((id.as_str(), logit)),
            None => unscored.push(id.as_str()),
        }
    }
    maxima.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| incoming_rank[a.0].cmp(&incoming_rank[b.0]))
            .then_with(|| a.0.cmp(b.0))
    });
    let mut cross_rank: HashMap<&str, usize> = HashMap::new();
    for (index, (id, _)) in maxima.iter().enumerate() {
        cross_rank.insert(id, index + 1);
    }
    for (offset, id) in unscored.iter().enumerate() {
        cross_rank.insert(id, maxima.len() + offset + 1);
    }
    let k = rrf_k as f64;
    let score = |id: &str| 1.0 / (k + incoming_rank[id] as f64) + 1.0 / (k + cross_rank[id] as f64);
    let mut fused: Vec<&str> = head_ids.iter().map(String::as_str).collect();
    fused.sort_by(|a, b| {
        score(b)
            .partial_cmp(&score(a))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| incoming_rank[a].cmp(&incoming_rank[b]))
            .then_with(|| a.cmp(b))
    });
    fused
        .into_iter()
        .map(str::to_string)
        .chain(tail.iter().cloned())
        .collect()
}

/// Up to `limit` span texts of one candidate, in the order the scorer should
/// see them. Twin of Swift `CrossEncoderStage.selectSpans`.
///
/// With stored span rows and a query vector (the registered span encoder's),
/// the rows are ranked by their int8 cosine against the query (`dot_query`,
/// ties by span index) and the best `limit` are rebuilt from the content's
/// word list by `[start_word, end_word)`. Without rows or a vector the
/// content is windowed with the spanner (`window_words` / `overlap_divisor`,
/// at most `limit` spans), so a record whose span rows have not drained yet
/// is still scored. Empty spans are dropped; an empty content yields no
/// spans (unscored).
pub fn select_spans(
    content: &str,
    rows: Option<&[SpanRerankVector]>,
    query_vector: Option<&[f32]>,
    limit: usize,
    window_words: usize,
    overlap_divisor: usize,
) -> Vec<String> {
    if limit == 0 {
        return Vec::new();
    }
    let words = spanner::words(content);
    if words.is_empty() {
        return Vec::new();
    }
    let text = |start: usize, end: usize| -> Option<String> {
        let lo = start.min(words.len());
        let hi = end.min(words.len()).max(lo);
        (hi > lo).then(|| words[lo..hi].join(" "))
    };
    if let (Some(rows), Some(query)) = (rows, query_vector) {
        if !rows.is_empty() && !query.is_empty() {
            let mut ranked: Vec<(&SpanRerankVector, f32)> = rows
                .iter()
                .filter(|row| row.int8.len() == query.len())
                .map(|row| (row, dot_query(query, &row.int8, row.scale)))
                .collect();
            ranked.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.0.index.cmp(&b.0.index))
            });
            let texts: Vec<String> = ranked
                .iter()
                .take(limit)
                .filter_map(|(row, _)| text(row.start_word, row.end_word))
                .collect();
            if !texts.is_empty() {
                return texts;
            }
        }
    }
    spanner::spans(words.len(), window_words, overlap_divisor, limit)
        .into_iter()
        .take(limit)
        .filter_map(|(start, end)| text(start, end))
        .collect()
}

/// Reorder `hits` so its first `pool` entries follow `order` (a permutation
/// of their ids); entries beyond the pool keep their place. An id in `order`
/// that is not in the pool is ignored, and pool hits absent from `order` keep
/// their relative order after the ordered ones, so membership can never
/// change. Twin of Swift `CrossEncoderStage.reorder`.
pub fn reorder(hits: Vec<RecallHit>, pool: usize, order: &[String]) -> Vec<RecallHit> {
    let pool_count = pool.min(hits.len());
    let mut iter = hits.into_iter();
    let pool_hits: Vec<RecallHit> = iter.by_ref().take(pool_count).collect();
    let tail: Vec<RecallHit> = iter.collect();
    let mut by_id: HashMap<String, RecallHit> = HashMap::new();
    let pool_order: Vec<String> = pool_hits.iter().map(|h| h.id.clone()).collect();
    for hit in pool_hits {
        by_id.entry(hit.id.clone()).or_insert(hit);
    }
    let mut placed: HashSet<String> = HashSet::new();
    let mut out: Vec<RecallHit> = Vec::with_capacity(pool_count + tail.len());
    for id in order {
        if placed.contains(id) {
            continue;
        }
        if let Some(hit) = by_id.remove(id) {
            out.push(hit);
            placed.insert(id.clone());
        }
    }
    for id in pool_order {
        if let Some(hit) = by_id.remove(&id) {
            out.push(hit);
        }
    }
    out.extend(tail);
    out
}
