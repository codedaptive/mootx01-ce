//! Reasoning-lens tool surface — the 16 hard-bound lens tools.
//!
//! Mirrors Swift `LensTools.swift`. One arm per cataloged lens recipe;
//! each arm calls its `run_*` function directly (no generic run-by-name
//! dispatcher). Tool names use the `moot_lens_` prefix (e.g. `moot_lens_keystones`).
//!
//! Includes the 14 reasoning lenses (structure, topic, preference, surprise,
//! grounding/trust, associative, prediction, federated) and the 2 analytics
//! lenses (moot_lens_associations, moot_lens_concepts) that are cataloged
//! by AR_FCA_CAPABILITY_001.
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
    run_anticipate, run_association_rules, run_bias, run_constellation, run_contradiction,
    run_drift, run_estate_divergence, run_formal_concepts, run_free_association, run_keystones,
    run_latent_themes, run_mind_overlap, run_partial_cue_recall, run_theme_weather,
    run_trust_grounded_synthesis, run_tunnel_successor, CueMode,
};
use locus_kit::drawer_operational::ContentKind;
use substrate_ml::association_rule_mining::MiningThresholds;
use substrate_ml::formal_concept_analysis::BoundedConceptMiner;

use crate::dispatch::{
    error_result, opt_float, opt_integer, recall_frame, require_string, text_result, wall_now,
};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// The 16 lens tool names — 14 reasoning lenses plus 2 analytics lenses.
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
    // Analytics lenses (AR_FCA_CAPABILITY_001).
    "moot_lens_associations",
    "moot_lens_concepts",
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
            let top_k = opt_integer(args, "topK", 5) as usize;
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
            let walk_length = opt_integer(args, "walkLength", 10_000) as usize;
            let k = opt_integer(args, "k", 10) as usize;
            let out = run_free_association(&coord, &estate.handle, wing, seed, walk_length, k)
                .map_err(lens_error)?;
            Ok(list(
                "free_association",
                out.iter()
                    .map(|a| format!("{} activation={}", a.drawer_id, a.activation))
                    .collect(),
            ))
        }

        "moot_lens_theme_weather" => {
            let frame = recall_frame(args);
            let half_life = opt_float(args, "halfLifeSeconds", 604_800.0);
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
            let frame = recall_frame(args);
            let k = opt_integer(args, "k", 3) as usize;
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
            let frame = recall_frame(args);
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
            let frame = recall_frame(args);
            let threshold = opt_float(args, "threshold", 1.5) as f32;
            let out = run_contradiction(&coord, &estate.handle, frame, threshold, now)
                .map_err(lens_error)?;
            Ok(list(
                &format!("contradiction (considered {})", out.considered),
                out.outliers,
            ))
        }

        "moot_lens_trust_synthesis" => {
            let frame = recall_frame(args);
            let out = run_trust_grounded_synthesis(&coord, &estate.handle, frame, now)
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
            let mode = decode_cue_mode(args.get("mode").and_then(|v| v.as_str()));
            let k = opt_integer(args, "k", 5) as usize;
            let frame = recall_frame(args);
            match run_partial_cue_recall(&coord, &estate.handle, frame, anchor_id, mode, k, now) {
                Ok(matches) => Ok(list(
                    "partial_cue_recall",
                    matches
                        .iter()
                        .map(|m| format!("{} score={}", m.id, m.score))
                        .collect(),
                )),
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
            let k = opt_integer(args, "k", 5) as usize;
            let min_obs = opt_integer(args, "minObservations", 1) as u32;
            let frame = recall_frame(args);
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
            let k = opt_integer(args, "k", 5) as usize;
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
            let make_frame = || recall_frame(args);
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
            let make_frame = || recall_frame(args);
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
            // a co-occurrence matrix, mine pairwise association rules. Mirrors
            // Swift `LensTools.dispatch` case "moot_association_rules".
            let frame = recall_frame(args);
            let min_support = opt_float(args, "minSupport", 0.0);
            let min_confidence = opt_float(args, "minConfidence", 0.0);
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
            // bounded formal concepts. Mirrors Swift `LensTools.dispatch`
            // case "moot_formal_concepts".
            let frame = recall_frame(args);
            let min_support = opt_integer(args, "minSupport", 1) as usize;
            let max_intent_size = opt_integer(args, "maxIntentSize", 8) as usize;
            let max_concepts = opt_integer(args, "maxConcepts", 20) as usize;
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

        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown lens tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// Argument decoders
// ---------------------------------------------------------------------------

fn decode_cue_mode(name: Option<&str>) -> CueMode {
    match name {
        Some("aboutThis") => CueMode::AboutThis,
        Some("fromThen") => CueMode::FromThen,
        _ => CueMode::FeelsLike,
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
