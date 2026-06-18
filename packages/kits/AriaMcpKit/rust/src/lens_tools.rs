//! Reasoning-lens tool surface — the 21 hard-bound lens tools.
//!
//! Mirrors Swift `LensTools.swift`. One arm per cataloged lens recipe;
//! each arm calls its `run_*` function directly (no generic run-by-name
//! dispatcher). Tool names use the `moot_lens_` prefix (e.g. `moot_lens_keystones`).
//!
//! Includes the 14 reasoning lenses (structure, topic, preference, surprise,
//! grounding/trust, associative, prediction, federated), the 3 analytics
//! lenses (moot_lens_associations, moot_lens_concepts, moot_lens_apriori)
//! cataloged by AR_FCA_CAPABILITY_001, and the 4 temporal/information-
//! theoretic lenses (moot_lens_moment, moot_lens_rhythm, moot_lens_precedence,
//! moot_lens_complexity) added by the aria-tools mission.
//!
//! Arg surfaces mirror the Swift LensTools schemas. The `now: i64` that
//! the Rust `run_*` functions require is supplied by `crate::dispatch::wall_now()`;
//! tests exercise the dispatch layer end-to-end (with real in-memory estates)
//! rather than injecting a fixed `now`, so any time-sensitive lens result is
//! asserted on shape (non-empty, field present) rather than exact value.
//!
//! Lens-level refusals (e.g. anchor not in recalled set for partial_cue_recall)
//! surface as `error_result` (isError true), not transport faults — matching
//! the Swift discipline.

use std::collections::BTreeMap;

use cognition_kit::{
    run_anticipate, run_apriori_rules, run_association_rules, run_bias, run_complexity,
    run_constellation, run_contradiction, run_drift, run_estate_divergence, run_formal_concepts,
    run_free_association, run_keystones, run_latent_themes, run_mind_overlap, run_moment,
    run_partial_cue_recall, run_precedence, run_rhythm, run_theme_weather,
    run_trust_grounded_synthesis, run_tunnel_successor, CueMode,
};
use genius_locus_kit::{bridge_audit_event, event_lag_pairs};
use locus_kit::drawer_operational::ContentKind;
use substrate_ml::apriori_mining::AprioriThresholds;
use substrate_ml::association_rule_mining::MiningThresholds;
use substrate_ml::formal_concept_analysis::BoundedConceptMiner;
use substrate_ml::temporal_causality_fold::TemporalFieldCoord;

use crate::dispatch::{
    error_result, opt_float, opt_integer, optional_string, recall_frame, require_string,
    text_result, wall_now,
};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// The 21 lens tool names — 14 reasoning lenses, 3 analytics lenses, and
/// 4 temporal/information-theoretic lenses.
/// All names use the `moot_lens_` prefix to match Swift `LensTools.swift`.
pub const LENS_TOOLS: &[&str] = &[
    "moot_lens_keystones",
    "moot_lens_constellation",
    "moot_lens_free_association",
    "moot_lens_theme_weather",
    "moot_lens_latent_themes",
    "moot_lens_bias",
    "moot_lens_drift",
    "moot_lens_contradiction",
    "moot_lens_trust_synthesis",
    "moot_lens_partial_cue",
    "moot_lens_anticipate",
    "moot_lens_successors",
    "moot_lens_overlap",
    "moot_lens_divergence",
    // Analytics lenses (AR_FCA_CAPABILITY_001 + Apriori multi-antecedent).
    "moot_lens_associations",
    "moot_lens_concepts",
    "moot_lens_apriori",
    // Temporal lenses (Lenses 1–3, Time+Prediction).
    "moot_lens_moment",
    "moot_lens_rhythm",
    "moot_lens_precedence",
    // Information-theoretic lens (Lens 4, Topics).
    "moot_lens_complexity",
];

/// True when `name` is one of the lens tools.
pub fn is_lens_tool(name: &str) -> bool {
    LENS_TOOLS.contains(&name)
}

/// Dispatch a lens tool call. Same contract as `dispatch_tool`.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    match name {
        "moot_lens_keystones" => {
            let wing = require_string(args, "wing")?;
            let top_k = opt_integer(args, "topK", 5)? as usize;
            let ranked = run_keystones(&coord, &estate.handle, wing, top_k).map_err(lens_error)?;
            Ok(list(
                "keystones",
                ranked
                    .iter()
                    .map(|k| format!("{} centrality={}", k.id, k.centrality))
                    .collect(),
            ))
        }

        "moot_lens_constellation" => {
            let wing = require_string(args, "wing")?;
            let out = run_constellation(&coord, &estate.handle, wing).map_err(lens_error)?;
            Ok(list(
                "constellation",
                out.communities.iter().map(|c| c.join(", ")).collect(),
            ))
        }

        "moot_lens_free_association" => {
            let wing = require_string(args, "wing")?;
            let seed = require_string(args, "seedDrawerID")?;
            let walk_length = opt_integer(args, "walkLength", 10_000)? as usize;
            let k = opt_integer(args, "k", 10)? as usize;
            let out = run_free_association(&coord, &estate.handle, wing, seed, walk_length, k)
                .map_err(lens_error)?;
            // free_association is a forward walk; a seed with no outgoing tunnels
            // (or one not present in the wing) yields no associations. Return a
            // hint rather than a bare "0 results" that reads as an empty estate.
            if out.is_empty() {
                return Ok(text_result(
                    "free_association: 0 associations — the seed drawer has no outgoing tunnels to \
                     walk (this lens is a forward walk), or the seed is not in the given wing. Use \
                     moot_connection_map to see links pointing into this drawer.",
                ));
            }
            Ok(list(
                "free_association",
                out.iter()
                    .map(|a| format!("{} activation={}", a.drawer_id, a.activation))
                    .collect(),
            ))
        }

        "moot_lens_theme_weather" => {
            let frame = recall_frame(args)?;
            let half_life = opt_float(args, "halfLifeSeconds", 604_800.0)?;
            let weather = run_theme_weather(&coord, &estate.handle, frame, half_life, now)
                .map_err(lens_error)?;
            Ok(list(
                "theme_weather",
                weather
                    .iter()
                    .map(|w| format!("{} momentum={}", w.category, w.momentum))
                    .collect(),
            ))
        }

        "moot_lens_latent_themes" => {
            let frame = recall_frame(args)?;
            let k = opt_integer(args, "k", 3)? as usize;
            let themes =
                run_latent_themes(&coord, &estate.handle, frame, k, now).map_err(lens_error)?;
            Ok(list(
                &format!("latent_themes (k={})", themes.k),
                themes
                    .loadings
                    .iter()
                    .map(|l| format!("{} → theme {}", l.label, l.dominant_theme))
                    .collect(),
            ))
        }

        "moot_lens_bias" => {
            let reference = decode_reference(args)?;
            let report = run_bias(&coord, &estate.handle, &reference, now).map_err(lens_error)?;
            let mut lines = vec!["bias".to_owned()];
            lines.push("for:".to_owned());
            lines.extend(
                report
                    .biased_for
                    .iter()
                    .map(|c| format!("  {} bias={}", c.label, c.bias)),
            );
            lines.push("against:".to_owned());
            lines.extend(
                report
                    .biased_against
                    .iter()
                    .map(|c| format!("  {} bias={}", c.label, c.bias)),
            );
            lines.push("dismissal:".to_owned());
            lines.extend(
                report
                    .dismissal
                    .iter()
                    .map(|(r, rate)| format!("  {r} rate={rate}")),
            );
            lines.push("learned:".to_owned());
            lines.extend(report.learned.iter().map(|l| {
                format!(
                    "  {} strength={} (+{}/−{})",
                    l.label, l.strength, l.endorsements, l.dismissals
                )
            }));
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_drift" => {
            let frame = recall_frame(args)?;
            let split_at = require_iso8601(args, "splitAt")?;
            let out =
                run_drift(&coord, &estate.handle, frame, split_at, now).map_err(lens_error)?;
            Ok(text_result(&format!(
                "drift: before={} after={}\njensenShannon: {}\nklDivergence: {}",
                out.before_count,
                out.after_count,
                out.drift.jensen_shannon,
                out.drift.kl_divergence
            )))
        }

        "moot_lens_contradiction" => {
            let frame = recall_frame(args)?;
            let threshold = opt_float(args, "threshold", 1.5)? as f32;
            let out = run_contradiction(&coord, &estate.handle, frame, threshold, now)
                .map_err(lens_error)?;
            Ok(list(
                &format!("contradiction (considered {})", out.considered),
                out.outliers,
            ))
        }

        "moot_lens_trust_synthesis" => {
            let frame = recall_frame(args)?;
            // calibration_curve: None — v1.1.0 optional calibrated confidence
            // pass (MatrixCalibrationCurve); MCP surface does not yet expose it.
            let out = run_trust_grounded_synthesis(&coord, &estate.handle, frame, None, now)
                .map_err(lens_error)?;
            Ok(text_result(&format!(
                "trust_grounded_synthesis: {} drawer(s), {} high-trust\nranked: {}\nsummary: {}",
                out.ranked_ids.len(),
                out.high_trust_count,
                out.ranked_ids.join(", "),
                out.context.summary
            )))
        }

        "moot_lens_partial_cue" => {
            let anchor_id = require_string(args, "anchorID")?;
            let mode = decode_cue_mode(optional_string(args, "mode")?)?;
            let k = opt_integer(args, "k", 5)? as usize;
            let frame = recall_frame(args)?;
            match run_partial_cue_recall(&coord, &estate.handle, frame, anchor_id, mode, k, now) {
                Ok(matches) => {
                    // Discrimination signal: fingerprint-based scores tend to be
                    // near-flat on small corpora — surface this honestly.
                    let cue_scores: Vec<f64> = matches.iter().map(|m| m.score).collect();
                    let discrimination = crate::recall_discrimination::classify(&cue_scores);
                    let discrimination_line =
                        crate::recall_discrimination::result_line(discrimination);
                    let result_lines: Vec<String> = matches
                        .iter()
                        .map(|m| format!("{} score={}", m.id, m.score))
                        .collect();
                    let mut body =
                        format!("partial_cue_recall: {} result(s)", result_lines.len());
                    for line in &result_lines {
                        body.push_str(&format!("\n  - {}", line));
                    }
                    body.push('\n');
                    body.push_str(discrimination_line);
                    Ok(crate::dispatch::text_result(&body))
                }
                Err(cognition_kit::RecipeRunError::Substrate(ref se))
                    if se.operation == "recall" || se.detail.contains("not in") =>
                {
                    // Anchor not in recalled set — lens-level refusal.
                    Ok(error_result(&format!(
                        "anchor '{anchor_id}' is not in the recalled set"
                    )))
                }
                Err(e) => Ok(error_result(&format!("{e:?}"))),
            }
        }

        "moot_lens_anticipate" => {
            let target_kind_str = require_string(args, "targetKind")?;
            let target_kind = decode_content_kind(target_kind_str).ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "targetKind is not a content kind name",
                )
            })?;
            let k = opt_integer(args, "k", 5)? as usize;
            let min_obs = opt_integer(args, "minObservations", 1)? as u32;
            let frame = recall_frame(args)?;
            let predictions = run_anticipate(
                &coord,
                &estate.handle,
                frame,
                target_kind as u8,
                k,
                min_obs,
                now,
            )
            .map_err(lens_error)?;
            Ok(list(
                "anticipate",
                predictions
                    .iter()
                    .map(|p| {
                        let action_name = channel_name(p.action);
                        format!(
                            "action={action_name} successRate={} n={}",
                            p.success_rate, p.count
                        )
                    })
                    .collect(),
            ))
        }

        "moot_lens_successors" => {
            let wing = require_string(args, "wing")?;
            let anchor_id = require_string(args, "anchorID")?;
            let k = opt_integer(args, "k", 5)? as usize;
            let out = run_tunnel_successor(&coord, &estate.handle, wing, anchor_id, k)
                .map_err(lens_error)?;
            Ok(list(
                "tunnel_successor",
                out.iter()
                    .map(|s| format!("{} weight={}", s.id, s.weight))
                    .collect(),
            ))
        }

        "moot_lens_overlap" => {
            // estateIDB is presented as estateID to the resolver for estate B.
            // Both estates share the same coordinator Arc (single coordinator per
            // server); we call through coord already locked above with both handles.
            let estate_b = registry.resolve(args, "estateIDB")?;
            let frame = recall_frame(args)?;
            let make_frame = || frame.clone();
            let out = run_mind_overlap(&coord, &estate.handle, &estate_b.handle, make_frame, now)
                .map_err(lens_error)?;
            Ok(text_result(&format!(
                "mind_overlap: {} (a={}, b={} drawer(s))",
                out.overlap, out.a_count, out.b_count
            )))
        }

        "moot_lens_divergence" => {
            // Both estates share the same coordinator — coord (already locked
            // above) covers both handles. No need to re-lock.
            let estate_b = registry.resolve(args, "estateIDB")?;
            let frame = recall_frame(args)?;
            let make_frame = || frame.clone();
            let out =
                run_estate_divergence(&coord, &estate.handle, &estate_b.handle, make_frame, now)
                    .map_err(lens_error)?;
            Ok(text_result(&format!(
                "estate_divergence: jensenShannon={} klDivergence={}\na={} drawer(s), b={} drawer(s)",
                out.divergence.jensen_shannon, out.divergence.kl_divergence,
                out.a_count, out.b_count
            )))
        }

        "moot_lens_associations" => {
            // Analytics lens: recall drawers, project categorical facets into
            // a co-occurrence matrix, mine pairwise association rules.
            let frame = recall_frame(args)?;
            let min_support = opt_float(args, "minSupport", 0.0)?;
            let min_confidence = opt_float(args, "minConfidence", 0.0)?;
            let thresholds = MiningThresholds {
                min_support,
                min_confidence,
            };
            let out = run_association_rules(&coord, &estate.handle, frame, thresholds, now)
                .map_err(lens_error)?;
            let mut lines = vec![format!(
                "association_rules: {} rule(s) from {} drawer(s)",
                out.rules.len(),
                out.drawer_count
            )];
            if out.label_overflow {
                lines.push(
                    "note: label vocabulary was capped at 64; some labels were dropped".to_owned(),
                );
            }
            for rule in &out.rules {
                lines.push(format!(
                    "  {} → {}: sup={:.3} conf={:.3} lift={:.3}",
                    rule.antecedent, rule.consequent, rule.support, rule.confidence, rule.lift
                ));
            }
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_concepts" => {
            // Analytics lens: recall drawers, build a formal context, mine
            // bounded formal concepts.
            let frame = recall_frame(args)?;
            let min_support = opt_integer(args, "minSupport", 1)? as usize;
            let max_intent_size = opt_integer(args, "maxIntentSize", 8)? as usize;
            let max_concepts = opt_integer(args, "maxConcepts", 20)? as usize;
            let miner = BoundedConceptMiner::new(min_support, max_intent_size, max_concepts);
            let out = run_formal_concepts(&coord, &estate.handle, frame, miner, now)
                .map_err(lens_error)?;
            let mut lines = vec![format!(
                "formal_concepts: {} concept(s) from {} drawer(s)",
                out.concepts.len(),
                out.drawer_count
            )];
            for (i, concept) in out.concepts.iter().enumerate() {
                lines.push(format!("  concept {}: support={}", i + 1, concept.support));
                lines.push(format!("    intent: {}", concept.intent.join(", ")));
                lines.push(format!(
                    "    extent: {} drawer(s)",
                    concept.extent_drawer_ids.len()
                ));
            }
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_apriori" => {
            let min_support = opt_float(args, "minSupport", 0.0)?;
            let min_confidence = opt_float(args, "minConfidence", 0.0)?;
            let min_lift = opt_float(args, "minLift", 1.0)?;
            let max_k = opt_integer(args, "maxK", 3)? as usize;
            let thresholds = AprioriThresholds::new(min_support, min_confidence, min_lift, max_k);
            let out = run_apriori_rules(&coord, &estate.handle, thresholds).map_err(lens_error)?;
            let mut lines = vec![format!("apriori_rules: {} rule(s)", out.rules.len())];
            for rule in &out.rules {
                // Item has no Display impl; render as field:value to mirror
                // the packed key structure for human readability.
                let ant = rule
                    .antecedent
                    .iter()
                    .map(|i| format!("{}:{}", i.field, i.value))
                    .collect::<Vec<_>>()
                    .join(" & ");
                let cons = format!("{}:{}", rule.consequent.field, rule.consequent.value);
                lines.push(format!(
                    "  [{ant}] → {cons}: sup={:.3} conf={:.3} lift={:.3}",
                    rule.support, rule.confidence, rule.lift
                ));
            }
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_moment" => {
            // Primary window as an (start, end) epoch-seconds pair. The recipe
            // reads the fingerprints through the GLK surface
            // (coord.glk_fingerprints_captured) — aria-mcp no longer reaches
            // estate.store directly (B-1 layer discipline), matching the Swift
            // Moment.run flow over GeniusLocusKit.glkFingerprintsCaptured.
            let start_epoch = require_iso8601(args, "windowStart")?;
            let end_epoch = require_iso8601(args, "windowEnd")?;
            let window = (start_epoch, end_epoch);

            // Parse optional comparisonWindows array of {windowStart, windowEnd} objects.
            let comparison_windows: Vec<(i64, i64)> =
                if let Some(arr) = args.get("comparisonWindows").and_then(|v| v.as_array()) {
                    let mut result = Vec::with_capacity(arr.len());
                    for entry in arr {
                        let obj = entry.as_object().ok_or_else(|| {
                            JSONRPCError::new(
                                JSONRPCErrorCode::INVALID_PARAMS,
                                "each comparisonWindows entry must be an object",
                            )
                        })?;
                        let ws = obj
                            .get("windowStart")
                            .and_then(|v| v.as_str())
                            .and_then(parse_iso8601)
                            .ok_or_else(|| {
                                JSONRPCError::new(
                                    JSONRPCErrorCode::INVALID_PARAMS,
                                    "comparisonWindows entry missing valid windowStart",
                                )
                            })?;
                        let we = obj
                            .get("windowEnd")
                            .and_then(|v| v.as_str())
                            .and_then(parse_iso8601)
                            .ok_or_else(|| {
                                JSONRPCError::new(
                                    JSONRPCErrorCode::INVALID_PARAMS,
                                    "comparisonWindows entry missing valid windowEnd",
                                )
                            })?;
                        result.push((ws, we));
                    }
                    result
                } else {
                    vec![]
                };

            let out = run_moment(&coord, &estate.handle, window, &comparison_windows, now)
                .map_err(lens_error)?;
            let mut lines = vec![format!(
                "moment: window={} fingerprint(s), {} comparison(s) ranked",
                out.window_count,
                out.result.ranking.len()
            )];
            for (i, rank) in out.result.ranking.iter().enumerate() {
                lines.push(format!("  comparison[{i}] hammingDistance={}", rank.hamming_distance));
            }
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_rhythm" => {
            let bit = opt_integer(args, "bit", 0)? as usize;
            let bucket_seconds = opt_integer(args, "bucketSeconds", 86400)? as i64;
            let bucket_count = opt_integer(args, "bucketCount", 32)? as usize;
            let ending_at = require_iso8601(args, "endingAt")?;
            let top_k = opt_integer(args, "topK", 3)? as usize;
            let buckets: Vec<bool> = estate
                .store
                .fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
                .map_err(|e| {
                    JSONRPCError::new(
                        JSONRPCErrorCode::INTERNAL_ERROR,
                        format!("fingerprint_bit_series failed: {e:?}"),
                    )
                })?;
            let out = run_rhythm(&buckets, bucket_seconds as f64, top_k);
            Ok(list(
                &format!("rhythm (bucketCount={})", out.bucket_count),
                out.periods
                    .iter()
                    .map(|p| format!("period={}s magnitude={}", p.period_seconds, p.relative_magnitude))
                    .collect(),
            ))
        }

        "moot_lens_precedence" => {
            let start_epoch = require_iso8601(args, "windowStart")?;
            let end_epoch = require_iso8601(args, "windowEnd")?;
            // event_lag_pairs takes milliseconds; parse_iso8601 returns seconds.
            let lower_ms = start_epoch * 1000;
            let upper_ms = end_epoch * 1000;
            let target_field = require_string(args, "targetField")?;
            let target_value = require_string(args, "targetValue")?;
            let k = opt_integer(args, "k", 5)? as usize;
            // Fold the audit trail: collect all drawers, gather their audit events,
            // bridge to UnifiedAuditEntry, and filter to the window.
            let drawers = estate.store.all_drawers().map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("all_drawers failed: {e:?}"),
                )
            })?;
            let mut unified: Vec<genius_locus_kit::UnifiedAuditEntry> = Vec::new();
            for drawer in &drawers {
                let events = estate.store.audit_events_for_row(&drawer.id).map_err(|e| {
                    JSONRPCError::new(
                        JSONRPCErrorCode::INTERNAL_ERROR,
                        format!("audit_events_for_row failed: {e:?}"),
                    )
                })?;
                for event in &events {
                    unified.extend(bridge_audit_event(event));
                }
            }
            let temporal_entries = event_lag_pairs(&unified, lower_ms, upper_ms);
            let target = TemporalFieldCoord::new(
                target_field.to_owned(),
                target_value.to_owned(),
            );
            // foldWindowMinutes = 128 — matches Swift Precedence.foldWindowMinutes.
            let out = run_precedence(&temporal_entries, &target, k, 128);
            Ok(list(
                &format!("precedence (entryCount={})", out.entry_count),
                out.antecedents
                    .iter()
                    .map(|a| {
                        format!(
                            "{}={} lag={}min count={}",
                            a.source.field_path, a.source.value_repr,
                            a.lag_bucket, a.count
                        )
                    })
                    .collect(),
            ))
        }

        "moot_lens_complexity" => {
            let field_a = require_string(args, "fieldA")?;
            let field_b = optional_string(args, "fieldB")?;
            let frame = recall_frame(args)?;
            let out =
                run_complexity(&coord, &estate.handle, frame, field_a, field_b, now)
                    .map_err(lens_error)?;
            let mut lines = vec![
                format!("complexity: totalCount={}", out.total_count),
                format!("entropyA={}", out.result.entropy_a),
            ];
            if let Some(eb) = out.result.entropy_b {
                lines.push(format!("entropyB={eb}"));
            }
            if let Some(mi) = out.result.mutual_information {
                lines.push(format!("mutualInformation={mi}"));
            }
            Ok(text_result(&lines.join("\n")))
        }

        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown lens tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Argument decoders
// ---------------------------------------------------------------------------

fn decode_cue_mode(name: Option<&str>) -> Result<CueMode, JSONRPCError> {
    match name {
        None | Some("feelsLike") => Ok(CueMode::FeelsLike),
        Some("aboutThis") => Ok(CueMode::AboutThis),
        Some("fromThen") => Ok(CueMode::FromThen),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown mode: {unknown}"),
        )),
    }
}

fn decode_content_kind(name: &str) -> Option<ContentKind> {
    match name {
        "prose" => Some(ContentKind::Prose),
        "code" => Some(ContentKind::Code),
        "transcript" => Some(ContentKind::Transcript),
        "list" => Some(ContentKind::List),
        "structuredJSON" => Some(ContentKind::StructuredJson),
        "imageCaption" => Some(ContentKind::ImageCaption),
        "fingerprintOnly" => Some(ContentKind::FingerprintOnly),
        _ => None,
    }
}

fn decode_reference(
    args: &BTreeMap<String, JsonValue>,
) -> Result<Vec<(String, f64)>, JSONRPCError> {
    let Some(arr) = args.get("reference").and_then(|v| v.as_array()) else {
        return Ok(Vec::new());
    };
    arr.iter()
        .map(|element| {
            let obj = element.as_object().ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each reference entry needs string label and number mass",
                )
            })?;
            let label = obj.get("label").and_then(|v| v.as_str()).ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each reference entry needs string label",
                )
            })?;
            let mass = obj.get("mass").and_then(|v| v.as_f64()).ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each reference entry needs number mass",
                )
            })?;
            Ok((label.to_owned(), mass))
        })
        .collect()
}

/// Parse an ISO8601 timestamp to Unix seconds.
fn require_iso8601(args: &BTreeMap<String, JsonValue>, key: &str) -> Result<i64, JSONRPCError> {
    let raw = require_string(args, key)?;
    // Parse RFC3339/ISO8601 to Unix timestamp using basic string parsing.
    // The Rust standard library does not include a date parser; we use a
    // minimal implementation sufficient for the ISO8601 instants this tool
    // accepts (e.g. "2026-04-01T00:00:00Z").
    parse_iso8601(raw).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Argument {key} is not an ISO8601 instant: {raw}"),
        )
    })
}

/// Minimal ISO8601 UTC parser — handles the subset the server accepts.
/// Accepts "YYYY-MM-DDTHH:MM:SSZ" and "YYYY-MM-DDTHH:MM:SS+00:00".
fn parse_iso8601(s: &str) -> Option<i64> {
    // Trim Z / +00:00 suffixes; expect "YYYY-MM-DDTHH:MM:SS".
    let s = s
        .trim_end_matches('Z')
        .trim_end_matches("+00:00")
        .trim_end_matches("+0000");
    let parts: Vec<&str> = s.split('T').collect();
    if parts.len() != 2 {
        return None;
    }
    let date_parts: Vec<u64> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<u64> = parts[1].split(':').filter_map(|p| p.parse().ok()).collect();
    if date_parts.len() < 3 || time_parts.len() < 3 {
        return None;
    }
    let (y, m, d) = (date_parts[0], date_parts[1], date_parts[2]);
    let (h, min, sec) = (time_parts[0], time_parts[1], time_parts[2]);
    // Days since 1970-01-01 via a simplified algorithm.
    let days = days_from_ymd(y as i64, m as i64, d as i64)?;
    Some(days * 86400 + h as i64 * 3600 + min as i64 * 60 + sec as i64)
}

fn days_from_ymd(y: i64, m: i64, d: i64) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // Algorithm from https://www.pement.org/awk/epoch.awk — Julian Day Number
    // relative to Unix epoch.
    let a = (14 - m) / 12;
    let yr = y + 4800 - a;
    let mo = m + 12 * a - 3;
    let jdn = d + (153 * mo + 2) / 5 + 365 * yr + yr / 4 - yr / 100 + yr / 400 - 32045;
    // Unix epoch is JDN 2440588.
    Some(jdn - 2_440_588)
}

/// Map a capture-channel raw byte to a name string.
/// Mirrors Swift `LensTools.channelName(_:)`.
fn channel_name(raw: u8) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    // from_raw returns CaptureChannel (not Option) — falls back to Typed for
    // unknown values, matching the LocusKit convention.
    let ch = CaptureChannel::from_raw(raw as i64);
    format!("{ch:?}")
}

// ---------------------------------------------------------------------------
// Result helpers
// ---------------------------------------------------------------------------

fn list(heading: &str, items: Vec<String>) -> serde_json::Value {
    let mut lines = vec![format!("{heading}: {} result(s)", items.len())];
    lines.extend(items.into_iter().map(|i| format!("  - {i}")));
    text_result(&lines.join("\n"))
}

fn lens_error(e: cognition_kit::RecipeRunError) -> JSONRPCError {
    JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
}
