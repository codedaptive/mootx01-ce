//! Reasoning-lens tool surface — the 23 hard-bound lens tools.
//!
//! Mirrors Swift `LensTools.swift`. One arm per cataloged lens recipe;
//! each arm calls its `run_*` function directly (no generic run-by-name
//! dispatcher). Tool names use the `moot_lens_` prefix (e.g. `moot_lens_keystones`).
//!
//! Includes the 16 reasoning lenses (structure, topic, preference, surprise,
//! grounding/trust, associative, prediction, federated, the new genuine
//! moot_lens_contradiction, and the diffusion node lens moot_lens_node_motion),
//! the 3 analytics lenses (moot_lens_associations,
//! moot_lens_concepts, moot_lens_apriori) cataloged by AR_FCA_CAPABILITY_001,
//! and the 4 temporal/information-theoretic lenses (moot_lens_moment,
//! moot_lens_rhythm, moot_lens_precedence, moot_lens_complexity) added by
//! the aria-tools mission. moot_lens_cohesion (renamed from moot_lens_contradiction)
//! detects content-cohesion outliers; moot_lens_contradiction detects genuine
//! semantic contradictions via contradicts-tunnels and conflicting KG facts.
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
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_operational::ContentKind;
use locus_kit::tunnel_operational::TunnelKind;
use substrate_ml::apriori_mining::AprioriThresholds;
use substrate_ml::association_rule_mining::MiningThresholds;
use substrate_ml::formal_concept_analysis::BoundedConceptMiner;
use substrate_ml::temporal_causality_fold::TemporalFieldCoord;

use crate::dispatch::{
    clamp_limit, error_result, opt_float, opt_integer, optional_integer, optional_string,
    recall_frame, require_string, text_result, wall_now, LIMIT_HARD_CEILING,
};
use crate::estate_registry::EstateRegistry;
use crate::interface_tools::epoch_to_iso8601;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// The 23 lens tool names — 16 reasoning lenses (including the new genuine
/// moot_lens_contradiction and the diffusion node lens moot_lens_node_motion),
/// 3 analytics lenses, and 4 temporal/information-theoretic lenses.
/// All names use the `moot_lens_` prefix to match Swift `LensTools.swift`.
pub const LENS_TOOLS: &[&str] = &[
    "moot_lens_keystones",
    "moot_lens_constellation",
    "moot_lens_free_association",
    "moot_lens_theme_weather",
    "moot_lens_latent_themes",
    "moot_lens_bias",
    "moot_lens_drift",
    // Diffusion node layer (ADR-DIFFUSION-001): a single memory's motion over time.
    "moot_lens_node_motion",
    // moot_lens_cohesion: content-cohesion outlier detector (renamed from
    // moot_lens_contradiction; backed by CognitionKit run_contradiction).
    "moot_lens_cohesion",
    // moot_lens_contradiction: genuine semantic contradiction detector —
    // contradicts-tunnels + KG facts with conflicting objects for the same
    // subject+predicate key.
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
    // resolve_direct: primary estate is restricted to the default (Item 3 hardening).
    // The estateIDB comparison estate inside the overlap/divergence arms uses
    // registry.resolve(args, "estateIDB") directly — unrestricted cross-estate
    // reads for lens comparison are opt-in via the estateIDB argument.
    let estate = registry.resolve_direct(args)?;
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    match name {
        "moot_lens_keystones" => {
            // ADR-017 §3 bridge consumer: user-supplied wing name passed to LocusKit lens API.
            let wing = require_string(args, "wing")?;
            let top_k = crate::dispatch::clamp_limit(
                Some(opt_integer(args, "topK", 5)?), "topK", 5, crate::dispatch::LIMIT_HARD_CEILING
            )?;
            let ranked = run_keystones(&coord, &estate.handle, wing, top_k, now as f64)
                .map_err(lens_error)?;
            Ok(list(
                "keystones",
                ranked
                    .iter()
                    .map(|k| format!("{} centrality={}", k.id, k.centrality))
                    .collect(),
            ))
        }

        "moot_lens_constellation" => {
            // ADR-017 §3 bridge consumer: user-supplied wing name passed to LocusKit lens API.
            let wing = require_string(args, "wing")?;
            let out = run_constellation(&coord, &estate.handle, wing, now as f64)
                .map_err(lens_error)?;
            Ok(list(
                "constellation",
                out.communities.iter().map(|c| c.join(", ")).collect(),
            ))
        }

        "moot_lens_free_association" => {
            // ADR-017 §3 bridge consumer: user-supplied wing name passed to LocusKit lens API.
            let wing = require_string(args, "wing")?;
            let seed = require_string(args, "seedDrawerID")?;
            // walkLength ceiling 100_000: walk steps are bounded separately from result
            // counts; the default (10_000) is well within the ceiling, but Int::MAX
            // exhausts CPU. Parity: Swift uses clampLimit with ceiling 100_000.
            let walk_length = crate::dispatch::clamp_limit(
                Some(opt_integer(args, "walkLength", 10_000)?),
                "walkLength", 10_000, 100_000,
            )?;
            let k = crate::dispatch::clamp_limit(
                Some(opt_integer(args, "k", 10)?), "k", 10, crate::dispatch::LIMIT_HARD_CEILING
            )?;
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

        "moot_lens_node_motion" => {
            // Diffusion, node layer (ADR-DIFFUSION-001): fold a single memory's
            // fresh audit history into its motion model — decay-weighted churn
            // volatility, UDC-anchor trajectory, reanchor flag — then classify a
            // write-time anomaly verdict. Mirrors Swift LensTools moot_lens_node_motion
            // (NodeMotionLens.run + classify over GeniusLocusKit.nodeAuditEntries).
            let row_id = require_string(args, "rowID")?;

            // Sensitivity gate — mirrors the default BitmapEvaluator ceiling
            // (SensitivityAtMost(.elevated)) that normal recall applies. Without
            // this check, audit metadata (volatility, event count, UDC trajectory)
            // for restricted/secret rows would be visible to any caller, bypassing
            // the access-control posture.
            //
            // Resolution order:
            //   1. Drawer not found (unknown id) → not-found error
            //   2. Drawer tombstoned             → not-found error
            //   3. Sensitivity restricted/secret → not-found error
            //   4. Otherwise                     → proceed to motion fold
            let drawer_opt = estate.store.get_drawer(row_id).map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("get_drawer failed: {e}"),
                )
            })?;
            let drawer = match drawer_opt {
                Some(d) => d,
                None => return Ok(error_result(&format!("memory not found: {row_id}"))),
            };
            if drawer.tombstoned_at.is_some() {
                return Ok(error_result(&format!("memory not found: {row_id}")));
            }
            // AdjectiveSensitivity lives in adjective_bitmap bits 6–11 (the same
            // field the BitmapEvaluator sensitivity ceiling gates in Swift). Extract
            // via the cookbook §2.3 shift: (adjective_bitmap >> 6) & 0x3F.
            let sensitivity = AdjectiveSensitivity::from_raw((drawer.adjective_bitmap >> 6) & 0x3F);
            if sensitivity == AdjectiveSensitivity::Restricted || sensitivity == AdjectiveSensitivity::Secret {
                return Ok(error_result(&format!("memory not found: {row_id}")));
            }

            // Read the memory's audit events and bridge them to unified entries —
            // the same accessor + bridge the precedence lens uses. audit_events_for_row
            // returns this row's events (genesis included for a real drawer).
            let events = estate.store.audit_events_for_row(row_id).map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("audit_events_for_row failed: {e}"),
                )
            })?;
            let mut entries: Vec<genius_locus_kit::UnifiedAuditEntry> = Vec::new();
            for event in &events {
                entries.extend(bridge_audit_event(event));
            }

            // fold filters by the row's EntryUUID; every bridged entry for this row
            // carries the same one (derived from the drawer UUID), so read it off the
            // first entry. No history => fold over the empty slice returns zero motion
            // (the EntryUUID is never displayed — the result echoes the caller's rowID
            // string, matching the Swift port). wall_now() and the fold's HLC
            // time base are both epoch MS (ADR-023) — no scaling.
            let row_uuid = entries
                .first()
                .map(|e| e.row_id)
                .unwrap_or(genius_locus_kit::audit::log::EntryUUID([0u8; 16]));
            let now_ms = now;
            let motion = neuron_kit::diffusion::node_motion::fold(
                &entries,
                row_uuid,
                now_ms,
                neuron_kit::diffusion::node_motion::DEFAULT_NODE_LAMBDA,
            );
            let anomaly = neuron_kit::diffusion::node_anomaly::classify(
                &motion,
                neuron_kit::diffusion::node_anomaly::DEFAULT_CHURN_THRESHOLD,
            );

            let trajectory = motion
                .anchor_trajectory
                .iter()
                .map(|c| c.to_string())
                .collect::<Vec<_>>()
                .join(" → ");
            let verdict = if anomaly.is_churning {
                "churning"
            } else if anomaly.reanchored {
                "reanchored"
            } else {
                "stable"
            };
            let current_anchor = motion
                .current_anchor()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "none".to_string());
            let warn = if anomaly.is_anomalous() { "  ⚠" } else { "" };
            Ok(text_result(&format!(
                "node_motion: {row_id}\n  \
                 volatility: {:.3} over {} event(s)\n  \
                 topic trajectory: {}\n  \
                 reanchored: {}  current_anchor: {}\n  \
                 anomaly: {verdict}{warn}",
                motion.volatility,
                motion.event_count,
                if trajectory.is_empty() {
                    "(none)".to_string()
                } else {
                    trajectory
                },
                motion.reanchored(),
                current_anchor,
            )))
        }

        "moot_lens_cohesion" => {
            // Content-cohesion outlier detector: flags recalled memories whose
            // content cohesion with their peers is anomalously low.
            // Backed by CognitionKit `run_contradiction` (the statistical
            // cohesion algorithm); renamed at the MCP surface to avoid
            // confusion with the genuine semantic contradiction detector below.
            let frame = recall_frame(args)?;
            let threshold = opt_float(args, "threshold", 1.5)? as f32;
            let out = run_contradiction(&coord, &estate.handle, frame, threshold, now)
                .map_err(lens_error)?;
            Ok(list(
                &format!("cohesion_outliers (considered {})", out.considered),
                out.outliers,
            ))
        }

        "moot_lens_contradiction" => {
            // Genuine semantic contradiction detector. Two signals:
            // 1. Drawer pairs linked by an active `contradicts` tunnel.
            // 2. KG facts with conflicting objects for the same
            //    (subject.to_lowercase, predicate.to_lowercase) key.
            // No recall frame needed — scans the full estate.
            // all_tunnels returns VerbDispatchError, not RecipeRunError — use
            // the direct JSONRPCError mapping rather than lens_error.
            let all_tunnels = coord
                .all_tunnels(&estate.handle)
                .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::interface_tools::describe_verb_dispatch_error(&e)))?;
            // MCP disclosure ceiling: drop Restricted/Secret tunnels before any output.
            // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
            // that normal recall applies via insert_defaults. Filter at the ARIA tool boundary
            // only — all_tunnels() has internal callers that need the full set.
            let contradicts_tunnels: Vec<_> = all_tunnels
                .into_iter()
                .filter(|t| {
                    t.kind == TunnelKind::Contradicts
                        && t.tombstoned_at.is_none()
                        && t.adjective_sensitivity().is_bulk_exportable()
                })
                .collect();

            // Source-ID gate: an exportable tunnel may still point at a
            // Restricted/Secret drawer. For each endpoint id we are about to
            // emit, hide it if it references a drawer OUTSIDE the sensitivity
            // ceiling. Non-drawer strings (wing fallbacks) are never in the
            // store and pass through. Parity with the fact_search/timeline
            // source gating and the Swift contradiction lens.
            let hidden_tunnel_endpoint_ids: std::collections::HashSet<String> = {
                let mut seen = std::collections::HashSet::new();
                let mut hidden = std::collections::HashSet::new();
                for id in contradicts_tunnels
                    .iter()
                    .take(50)
                    .flat_map(|t| [t.source_drawer_id.as_ref(), t.target_drawer_id.as_ref()])
                    .flatten()
                    .filter(|id| seen.insert((*id).clone()))
                {
                    if let Ok(Some(drawer)) = estate.store.get_drawer(id) {
                        if !drawer.adjective_sensitivity().is_bulk_exportable() {
                            hidden.insert(id.clone());
                        }
                    }
                }
                hidden
            };

            let mut lines: Vec<String> = Vec::new();
            if contradicts_tunnels.is_empty() {
                lines.push("contradicts_tunnels: none".to_string());
            } else {
                lines.push(format!("contradicts_tunnels: {}", contradicts_tunnels.len()));
                // ADR-017 §3 bridge consumer: source_wing/target_wing used as
                // display fallback when drawer IDs are absent on tunnel metadata.
                for t in contradicts_tunnels.iter().take(50) {
                    let src = match t.source_drawer_id.as_deref() {
                        Some(id) if hidden_tunnel_endpoint_ids.contains(id) => "<hidden>",
                        Some(id) => id,
                        None => t.source_wing.as_str(),
                    };
                    let tgt = match t.target_drawer_id.as_deref() {
                        Some(id) if hidden_tunnel_endpoint_ids.contains(id) => "<hidden>",
                        Some(id) => id,
                        None => t.target_wing.as_str(),
                    };
                    lines.push(format!("  {} contradicts {} (tunnel {})", src, tgt, t.id));
                }
            }

            // recall_kg_facts returns VerbDispatchError — same mapping as above.
            let all_facts_raw = coord
                .recall_kg_facts(&estate.handle)
                .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::interface_tools::describe_verb_dispatch_error(&e)))?;
            // MCP disclosure ceiling: drop Restricted/Secret facts before any output.
            // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
            // that normal recall applies via insert_defaults. Filter at the ARIA tool boundary
            // only — recall_kg_facts has internal callers that need the full set.
            let all_facts: Vec<_> = all_facts_raw
                .into_iter()
                .filter(|f| f.adjective_sensitivity().is_bulk_exportable())
                .collect();
            // Group facts by (subject_lower, predicate_lower).
            let mut facts_by_key: BTreeMap<String, Vec<_>> = BTreeMap::new();
            for fact in &all_facts {
                let key = format!(
                    "{}|{}",
                    fact.subject.to_lowercase(),
                    fact.predicate.to_lowercase()
                );
                facts_by_key.entry(key).or_default().push(fact);
            }
            let conflicting: Vec<_> = facts_by_key
                .iter()
                .filter(|(_, facts)| {
                    let objects: std::collections::HashSet<_> =
                        facts.iter().map(|f| f.object.to_lowercase()).collect();
                    objects.len() > 1
                })
                .collect();

            // Source-ID gate: an exportable fact may still cite a
            // Restricted/Secret source drawer. Hide those source ids at the
            // boundary. Parity with fact_search/timeline source gating.
            let hidden_fact_source_ids: std::collections::HashSet<String> = {
                let mut seen = std::collections::HashSet::new();
                let mut hidden = std::collections::HashSet::new();
                for id in all_facts
                    .iter()
                    .map(|f| &f.source_drawer_id)
                    .filter(|id| seen.insert((*id).clone()))
                {
                    if let Ok(Some(drawer)) = estate.store.get_drawer(id) {
                        if !drawer.adjective_sensitivity().is_bulk_exportable() {
                            hidden.insert(id.clone());
                        }
                    }
                }
                hidden
            };

            if conflicting.is_empty() {
                lines.push("conflicting_facts: none".to_string());
            } else {
                lines.push(format!(
                    "conflicting_facts: {} subject+predicate pair(s)",
                    conflicting.len()
                ));
                for (key, facts) in conflicting.iter().take(20) {
                    let parts: Vec<_> = key.splitn(2, '|').collect();
                    lines.push(format!(
                        "  [{}] {}",
                        parts.first().copied().unwrap_or(""),
                        parts.get(1).copied().unwrap_or("")
                    ));
                    for fact in *facts {
                        // filed_at is epoch milliseconds (ADR-023); format as
                        // ISO8601 to match the Swift contradiction lens and
                        // substrate-wide date conventions.
                        let source_field = if hidden_fact_source_ids.contains(&fact.source_drawer_id) {
                            "<hidden>".to_string()
                        } else {
                            fact.source_drawer_id.clone()
                        };
                        lines.push(format!(
                            "    {}  object=[{}]  source={}  filed={}",
                            fact.id, fact.object, source_field,
                            epoch_to_iso8601(fact.filed_at)
                        ));
                    }
                }
            }
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_trust_synthesis" => {
            let frame = recall_frame(args)?;
            // calibration_curve: None — the MCP surface does not expose the optional
            // calibrated-confidence pass (MatrixCalibrationCurve).
            // node_names: empty — the MCP surface does not plumb display names from the node tree.
            let node_names = std::collections::HashMap::new();
            let out = run_trust_grounded_synthesis(&coord, &estate.handle, frame, None, now, &node_names)
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
                // RecipeRunError implements Display — forward it cleanly so no
                // internal Rust type names (RecipeRunError::Substrate etc.) reach
                // the agent boundary.
                Err(e) => Ok(error_result(&format!("{e}"))),
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
                            "action={action_name} successRate={:.1} n={}",
                            p.success_rate, p.count
                        )
                    })
                    .collect(),
            ))
        }

        "moot_lens_successors" => {
            // ADR-017 §3 bridge consumer: user-supplied wing name passed to LocusKit lens API.
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

            // Reject self-comparison — overlap of an estate with itself always
            // produces a degenerate result (overlap=1.0) that provides no useful
            // signal. Mirrors Swift LensTools self-comparison guard.
            if estate_b.handle.estate_uuid == estate.handle.estate_uuid {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "estateIDB resolves to the same estate as estateID; self-comparison is not meaningful for overlap.",
                ));
            }

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

            // Reject self-comparison — divergence of an estate with itself always
            // produces a degenerate result (JS=0) that provides no useful signal.
            // Mirrors Swift LensTools self-comparison guard.
            if estate_b.handle.estate_uuid == estate.handle.estate_uuid {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "estateIDB resolves to the same estate as estateID; self-comparison is not meaningful for divergence.",
                ));
            }

            let frame = recall_frame(args)?;
            let make_frame = || frame.clone();
            // Node-name map: the MCP surface does not yet plumb display names
            // from the node tree; pass empty for now.
            let node_names = std::collections::HashMap::new();
            let out =
                run_estate_divergence(&coord, &estate.handle, &estate_b.handle, make_frame, now, &node_names)
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
            // Route limit through clamp_limit so negative and over-ceiling values
            // are rejected/clamped. Parity: Swift moot_lens_associations uses
            // ToolDispatcher.clampLimit with the same ceiling.
            let mut frame = recall_frame(args)?;
            let limit = clamp_limit(
                optional_integer(args, "limit")?, "limit", 20, LIMIT_HARD_CEILING
            )?;
            frame.limit = Some(limit);
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
            // Route limit through clamp_limit so negative and over-ceiling values
            // are rejected/clamped. Parity: Swift moot_lens_concepts uses
            // ToolDispatcher.clampLimit with the same ceiling.
            let mut frame = recall_frame(args)?;
            let limit = clamp_limit(
                optional_integer(args, "limit")?, "limit", 20, LIMIT_HARD_CEILING
            )?;
            frame.limit = Some(limit);
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
                // Render each Item as "Item(field: F, value: V)" to mirror Swift's
                // default struct interpolation "\($0)" on AprioriRule.antecedent
                // (Swift Item has no custom description; the compiler synthesises
                // "Item(field: F, value: V)"). This matches the Swift live-drive output
                // that reads the audit log: e.g. "[Item(field: 1, value: 145)] → Item(field: 2, value: 0)".
                let ant = rule
                    .antecedent
                    .iter()
                    .map(|i| format!("Item(field: {}, value: {})", i.field, i.value))
                    .collect::<Vec<_>>()
                    .join(" & ");
                let cons = format!("Item(field: {}, value: {})", rule.consequent.field, rule.consequent.value);
                lines.push(format!(
                    "  [{ant}] → {cons}: sup={:.3} conf={:.3} lift={:.3}",
                    rule.support, rule.confidence, rule.lift
                ));
            }
            Ok(text_result(&lines.join("\n")))
        }

        "moot_lens_moment" => {
            // Primary window as an (start, end) epoch-milliseconds pair (ADR-023).
            // The recipe reads the fingerprints through the GLK surface
            // (coord.glk_fingerprints_captured) — aria-mcp no longer reaches
            // estate.store directly (B-1 layer discipline), matching the Swift
            // Moment.run flow over GeniusLocusKit.glkFingerprintsCaptured.
            let start_epoch = require_iso8601(args, "windowStart")?;
            let end_epoch = require_iso8601(args, "windowEnd")?;
            // Guard: reject reversed windows (inverted range → nonsense histogram math)
            // and excessively wide windows (decades-long scan exhausts memory).
            // Parity: Swift moot_lens_moment uses requireWindowRange with the same checks.
            let window = require_window_range(start_epoch, end_epoch)?;

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
                        // Guard each comparison window the same way as the primary window.
                        result.push(require_window_range(ws, we)?);
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
            let top_k = crate::dispatch::clamp_limit(
                Some(opt_integer(args, "topK", 3)?), "topK", 3, crate::dispatch::LIMIT_HARD_CEILING
            )?;
            let buckets: Vec<bool> = estate
                .store
                .fingerprint_bit_series(bit, bucket_seconds, bucket_count, ending_at)
                .map_err(|e| {
                    JSONRPCError::new(
                        JSONRPCErrorCode::INTERNAL_ERROR,
                        format!("fingerprint_bit_series failed: {e}"),
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
            // Guard: reject reversed windows (nonsense causal-pair output) and
            // excessively wide windows. Same guards as moot_lens_moment.
            // Parity: Swift moot_lens_precedence uses requireWindowRange.
            require_window_range(start_epoch, end_epoch)?;
            // Both the eventTime pre-filter and event_lag_pairs operate in epoch
            // milliseconds (ADR-023): require_iso8601 returns ms and drawer
            // event_time is ms, so the bounds are used directly with no scaling.
            let lower_ms = start_epoch;
            let upper_ms = end_epoch;
            let target_field = require_string(args, "targetField")?;
            let target_value = require_string(args, "targetValue")?;
            let k = crate::dispatch::clamp_limit(
                Some(opt_integer(args, "k", 5)? as i64), "k", 5, crate::dispatch::LIMIT_HARD_CEILING
            )?;
            // Option A (Bob's ruling): filter drawers by eventTime BEFORE gathering
            // audit entries — only drawers whose event_time (epoch milliseconds,
            // resolved to filed_at when no explicit back-date was supplied) falls
            // within [lower_ms, upper_ms] contribute causal pairs. The causality
            // fold (HLC ordering inside the audit log) is unchanged; we are gating
            // WHICH drawers participate, not how their entries are ordered.
            // Drawers without an explicit eventTime use filed_at as the fallback
            // (resolved eagerly at construction in LocusKit::Drawer::new, so
            // event_time is always set — there is no None case).
            let drawers = estate.store.all_drawers().map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INTERNAL_ERROR,
                    format!("all_drawers failed: {e}"),
                )
            })?;
            // Pre-filter by eventTime window (epoch milliseconds comparison).
            let mut unified: Vec<genius_locus_kit::UnifiedAuditEntry> = Vec::new();
            for drawer in drawers.iter().filter(|d| {
                // event_time is epoch milliseconds; always set (falls back to filed_at).
                d.event_time >= lower_ms && d.event_time <= upper_ms
            }) {
                let events = estate.store.audit_events_for_row(&drawer.id).map_err(|e| {
                    JSONRPCError::new(
                        JSONRPCErrorCode::INTERNAL_ERROR,
                        format!("audit_events_for_row failed: {e}"),
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

            // Validate field names before calling the recipe. The complexity recipe
            // returns entropy=-0 for unknown fields, producing a misleading success
            // result. Reject early with the valid list. Mirrors Swift LensTools.
            // ADR-017 §3 bridge consumer: "room" and "wing" are display-bridge
            // metadata field names enumerated for the complexity lens.
            const VALID_COMPLEXITY_FIELDS: &[&str] =
                &["addedBy", "embeddingModelID", "room", "wing"];
            if !VALID_COMPLEXITY_FIELDS.contains(&field_a) {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!(
                        "Unknown fieldA: {field_a}. Valid fields: {}",
                        VALID_COMPLEXITY_FIELDS.join(", ")
                    ),
                ));
            }
            if let Some(fb) = field_b {
                if !VALID_COMPLEXITY_FIELDS.contains(&fb) {
                    return Err(JSONRPCError::new(
                        JSONRPCErrorCode::INVALID_PARAMS,
                        format!(
                            "Unknown fieldB: {fb}. Valid fields: {}",
                            VALID_COMPLEXITY_FIELDS.join(", ")
                        ),
                    ));
                }
            }

            let frame = recall_frame(args)?;
            let out =
                run_complexity(&coord, &estate.handle, frame, field_a, field_b, now)
                    .map_err(lens_error)?;
            // Normalize -0.0 to 0.0 before formatting. Rust's f32 Display renders
            // -0.0f32 as "-0", while Swift's Double interpolation renders -0.0 as
            // "-0.0". Neither matches the canonical "0" Swift outputs for the
            // degenerate/empty case. Normalise: if the value is zero (positive or
            // negative), render as "0" to match Swift's output.
            let entropy_a = if out.result.entropy_a == 0.0 { 0.0f32 } else { out.result.entropy_a };
            let mut lines = vec![
                format!("complexity: totalCount={}", out.total_count),
                format!("entropyA={entropy_a}"),
            ];
            if let Some(eb) = out.result.entropy_b {
                let eb = if eb == 0.0 { 0.0f32 } else { eb };
                lines.push(format!("entropyB={eb}"));
            }
            if let Some(mi) = out.result.mutual_information {
                let mi = if mi == 0.0 { 0.0f32 } else { mi };
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

/// Validate a `(start, end)` epoch-milliseconds pair (ADR-023) before use as a
/// query window.
///
/// Two guards are applied:
///   1. `start <= end` — a reversed window is a client error. Rust `RangeInclusive`
///      would silently produce an empty iterator on a reversed range, masking the
///      bug; rejecting early surfaces a proper `invalidParams` instead.
///   2. Max span cap — a window spanning decades can scan the entire corpus and
///      exhaust memory. Cap is 3 years (≈ 94 608 000 000 ms), generous for any
///      legitimate analytical query. Matches the Swift `requireWindowRange` cap
///      (`3 * 365.25 * 24 * 60 * 60` seconds, scaled to ms here).
fn require_window_range(start: i64, end: i64) -> Result<(i64, i64), JSONRPCError> {
    if start > end {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("windowStart must be ≤ windowEnd; got start={start} end={end}"),
        ));
    }
    // 3 * 365.25 days in ms = 94_608_000 s * 1000. Matches Swift's
    // `maxDurationSeconds` compared in Date-space (seconds); ms bounds here
    // require the ms-scaled cap.
    const MAX_MILLIS: i64 = 3 * 36525 * 24 * 3600 / 100 * 1000; // ≈ 94_608_000_000
    if end - start > MAX_MILLIS {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "window span must not exceed 3 years; reduce the range",
        ));
    }
    Ok((start, end))
}

/// Minimal ISO8601 UTC parser — handles the subset the server accepts.
/// Accepts "YYYY-MM-DDTHH:MM:SSZ" and "YYYY-MM-DDTHH:MM:SS+00:00".
/// Parse an ISO8601 instant to epoch MILLISECONDS (ADR-023).
///
/// Every lens bound this parses (windowStart/windowEnd, endingAt, splitAt) is
/// compared against drawer capture times, which are epoch milliseconds. The
/// bound must therefore be milliseconds too: the `TypedValue::Timestamp` codec
/// now interprets its i64 as ms, so feeding a seconds value would encode a
/// 1970-era instant and silently empty every temporal window. Mirrors the
/// Swift lens tools, which parse to `Date` (sub-second precision). Optional
/// fractional seconds (`.mmm`) are honoured; absent, the instant lands on a
/// whole second.
fn parse_iso8601(s: &str) -> Option<i64> {
    // Trim Z / +00:00 suffixes; expect "YYYY-MM-DDTHH:MM:SS[.mmm]".
    let s = s
        .trim_end_matches('Z')
        .trim_end_matches("+00:00")
        .trim_end_matches("+0000");
    // Split optional fractional seconds (.mmm…) → milliseconds (3 digits,
    // padded/truncated) BEFORE the ':' split, which would otherwise choke on
    // the dot embedded in the seconds field.
    let (s, millis) = if let Some(dot_pos) = s.rfind('.') {
        let frac: String = s[dot_pos + 1..].chars().take(3).collect();
        let mut ms: i64 = frac.parse().ok()?;
        for _ in frac.len()..3 {
            ms *= 10;
        }
        (&s[..dot_pos], ms)
    } else {
        (s, 0)
    };
    let parts: Vec<&str> = s.split('T').collect();
    if parts.len() != 2 {
        return None;
    }
    let date_parts: Vec<i64> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<i64> = parts[1].split(':').filter_map(|p| p.parse().ok()).collect();
    if date_parts.len() < 3 || time_parts.len() < 3 {
        return None;
    }
    let (y, m, d) = (date_parts[0], date_parts[1], date_parts[2]);
    let (h, min, sec) = (time_parts[0], time_parts[1], time_parts[2]);
    // Days since 1970-01-01 via a simplified algorithm, then scale to ms.
    let days = days_from_ymd(y, m, d)?;
    Some((days * 86400 + h * 3600 + min * 60 + sec) * 1000 + millis)
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

/// Convert a `RecipeRunError` to a `JSONRPCError` for out-of-band lens
/// failures. Uses `Display` (not `Debug`) so no internal Rust type names
/// leak to the agent boundary. `RecipeRunError` implements `Display` with
/// clean English messages parity with the Swift port.
fn lens_error(e: cognition_kit::RecipeRunError) -> JSONRPCError {
    JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e}"))
}
