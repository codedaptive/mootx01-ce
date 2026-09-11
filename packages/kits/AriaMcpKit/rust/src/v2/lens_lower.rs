//! Direct lower-kit adapter for selected v2 lens operations.
//!
//! This module consumes the selected-estate admission issued by
//! `V2RecallLensAuthority`, invokes the CognitionKit engines directly, and
//! projects their typed results into compact rows.  It intentionally never
//! calls `lens_tools`, a v1 dispatcher, or a renderer.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use cognition_kit::{
    run_anticipate, run_apriori_rules, run_association_rules, run_bias, run_complexity,
    run_constellation, run_contradiction, run_drift, run_estate_divergence,
    run_formal_concepts_receipt, run_free_association, run_keystones, run_latent_themes,
    run_mind_overlap, run_moment, run_partial_cue_recall, run_precedence, run_theme_weather,
    run_trust_grounded_synthesis, run_tunnel_successor, CueMode,
};
use genius_locus_kit::{bridge_audit_event, event_lag_pairs, EstateCoordinator};
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_operational::ContentKind;
use locus_kit::filter::RecallFrame;
use locus_kit::tunnel_operational::{TunnelKind, TunnelLifecycle};
use substrate_ml::apriori_mining::AprioriThresholds;
use substrate_ml::association_rule_mining::MiningThresholds;
use substrate_ml::concept_implications::ConceptImplications;
use substrate_ml::formal_concept_analysis::{
    BoundedConceptMiner, ConceptCoverDeltas, FormalAttribute,
};
use substrate_ml::temporal_causality_fold::TemporalFieldCoord;

use crate::jsonrpc::JsonValue;

use super::recall_lens::{
    V2RecallLensAdmission, V2RecallLensLower, V2RecallLensOperation, V2RecallLensRequest,
    V2RecallLensResult, V2RecallLensValue,
};

const RESULT_LIMIT: usize = 500;
const WALK_LENGTH_LIMIT: usize = 100_000;
const COHESION_THRESHOLD: f32 = 1.5;

/// Direct adapter for v2 lens operations whose lower engines already
/// return typed data:
///
/// - `CognitionKit::run_keystones`
/// - `CognitionKit::run_constellation`
/// - `CognitionKit::run_free_association`
/// - `CognitionKit::run_bias`
/// - `CognitionKit::run_contradiction` (the content-cohesion engine)
/// - `CognitionKit::run_theme_weather`
/// - `CognitionKit::run_latent_themes`
/// - `CognitionKit::run_drift`
/// - `CognitionKit::run_trust_grounded_synthesis`
/// - `CognitionKit::run_partial_cue_recall`
/// - `CognitionKit::run_anticipate`
///
/// The coordinator is shared with the selected-estate authority.  Every lower
/// call uses `admission.estate_handle` and `admission.now_millis`; it never
/// performs name-based estate resolution.
pub struct CoordinatorRecallLensLower {
    coordinator: Arc<Mutex<EstateCoordinator>>,
}

/// Three years in milliseconds, matching the v1 window ceiling.
const MAXIMUM_WINDOW_MILLIS: i64 = (3.0 * 365.25 * 24.0 * 60.0 * 60.0 * 1000.0) as i64;

impl CoordinatorRecallLensLower {
    pub fn new(coordinator: Arc<Mutex<EstateCoordinator>>) -> Self {
        Self { coordinator }
    }

    fn keystones(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let wing = required_string(request, "wing")?;
        let top_k = string_limit(request, "topK", 5, RESULT_LIMIT)?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let keystones = run_keystones(
            &coordinator,
            &admission.estate_handle,
            wing,
            top_k,
            admission.now_millis as f64 / 1000.0,
        )
        .map_err(|_| ())?;

        Ok(result(
            request.operation,
            keystones
                .into_iter()
                .map(|keystone| {
                    row([
                        ("memory_id", JsonValue::String(keystone.id)),
                        ("centrality", JsonValue::Double(keystone.centrality)),
                    ])
                })
                .collect(),
        ))
    }

    fn constellation(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let wing = required_string(request, "wing")?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let constellation = run_constellation(
            &coordinator,
            &admission.estate_handle,
            wing,
            admission.now_millis as f64 / 1000.0,
        )
        .map_err(|_| ())?;

        Ok(result(
            request.operation,
            constellation
                .communities
                .into_iter()
                .map(|community| {
                    row([(
                        "memory_ids",
                        JsonValue::Array(community.into_iter().map(JsonValue::String).collect()),
                    )])
                })
                .collect(),
        ))
    }

    fn free_association(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let wing = required_string(request, "wing")?;
        let seed_memory_id = required_uuid(request, "seed_memory_id")?.to_string();
        let walk_length = string_limit(request, "walkLength", 10_000, WALK_LENGTH_LIMIT)?;
        let result_limit = string_limit(request, "k", 10, RESULT_LIMIT)?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let associations = run_free_association(
            &coordinator,
            &admission.estate_handle,
            wing,
            &seed_memory_id,
            walk_length,
            result_limit,
        )
        .map_err(|_| ())?;

        Ok(result(
            request.operation,
            associations
                .into_iter()
                .map(|association| {
                    row([
                        ("memory_id", JsonValue::String(association.drawer_id)),
                        ("activation", JsonValue::Double(association.activation)),
                    ])
                })
                .collect(),
        ))
    }

    fn bias(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let reference = reference(request)?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let report = run_bias(
            &coordinator,
            &admission.estate_handle,
            &reference,
            admission.now_millis,
        )
        .map_err(|_| ())?;

        let mut rows = Vec::new();
        rows.extend(report.biased_for.into_iter().map(|bias| {
            row([
                ("kind", JsonValue::String("for".to_owned())),
                ("label", JsonValue::String(bias.label)),
                ("estate_share", JsonValue::Double(bias.estate_share)),
                ("reference_share", JsonValue::Double(bias.reference_share)),
                ("bias", JsonValue::Double(bias.bias)),
            ])
        }));
        rows.extend(report.biased_against.into_iter().map(|bias| {
            row([
                ("kind", JsonValue::String("against".to_owned())),
                ("label", JsonValue::String(bias.label)),
                ("estate_share", JsonValue::Double(bias.estate_share)),
                ("reference_share", JsonValue::Double(bias.reference_share)),
                ("bias", JsonValue::Double(bias.bias)),
            ])
        }));
        rows.extend(report.dismissal.into_iter().map(|(label, rate)| {
            row([
                ("kind", JsonValue::String("dismissal".to_owned())),
                ("label", JsonValue::String(label)),
                ("rate", JsonValue::Double(rate)),
            ])
        }));
        rows.extend(report.learned.into_iter().map(|preference| {
            row([
                ("kind", JsonValue::String("learned".to_owned())),
                ("label", JsonValue::String(preference.label)),
                ("strength", JsonValue::Double(preference.strength)),
                (
                    "confidence_low",
                    JsonValue::Double(preference.confidence_low),
                ),
                (
                    "confidence_high",
                    JsonValue::Double(preference.confidence_high),
                ),
                ("endorsements", JsonValue::Integer(preference.endorsements)),
                ("dismissals", JsonValue::Integer(preference.dismissals)),
            ])
        }));

        Ok(result(request.operation, rows))
    }

    fn cohesion(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        // The only existing typed lower engine for this operation is the
        // estate content-cohesion engine.  Dataset cohesion has a distinct
        // store-resolving path and is deliberately not misrouted here.
        if request.values.contains_key("dataset_id") {
            return Err(());
        }

        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = run_contradiction(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            COHESION_THRESHOLD,
            admission.now_millis,
        )
        .map_err(|_| ())?;

        Ok(result(
            request.operation,
            vec![row([
                ("considered", usize_value(output.considered)?),
                (
                    "outlier_memory_ids",
                    JsonValue::Array(output.outliers.into_iter().map(JsonValue::String).collect()),
                ),
            ])],
        ))
    }

    fn contradiction(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        // The v2 projection consumes the persisted output of the atomic hunt
        // directly.  It intentionally never calls the v1 lens dispatcher or
        // reparses its rendered report.
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        // COUNT FIRST, THEN WITHHOLD. Filtering by sensitivity before counting
        // makes a restricted contradiction vanish from the total, so an estate
        // with three contradictions reports one and reads as more consistent
        // than it is. For a contradiction lens the count IS the product; the
        // rows stay redacted, only the tally is honest.
        let all_contradictions = coordinator
            .all_tunnels(&admission.estate_handle)
            .map_err(|_| ())?
            .into_iter()
            .filter(|tunnel| {
                tunnel.kind == TunnelKind::Contradicts
                    && tunnel.tombstoned_at.is_none()
                    && matches!(tunnel.lifecycle(), TunnelLifecycle::Active | TunnelLifecycle::Proposed)
            })
            .collect::<Vec<_>>();
        let total_contradiction_count = all_contradictions.len() as i64;
        let tunnels = all_contradictions
            .into_iter()
            .filter(|tunnel| tunnel.adjective_sensitivity().is_bulk_exportable())
            .collect::<Vec<_>>();
        let withheld_contradiction_count = total_contradiction_count - tunnels.len() as i64;
        let emitted_tunnels = tunnels.iter().take(50).collect::<Vec<_>>();
        let endpoint_ids = emitted_tunnels
            .iter()
            .flat_map(|tunnel| [tunnel.source_drawer_id.as_ref(), tunnel.target_drawer_id.as_ref()])
            .flatten()
            .cloned()
            .collect::<BTreeSet<_>>();
        let hidden_endpoint_ids = coordinator
            .all_drawers(&admission.estate_handle)
            .map_err(|_| ())?
            .into_iter()
            .filter(|drawer| endpoint_ids.contains(&drawer.id) && !drawer.adjective_sensitivity().is_bulk_exportable())
            .map(|drawer| drawer.id)
            .collect::<BTreeSet<_>>();
        let contradicts_tunnels = emitted_tunnels
            .into_iter()
            .map(|tunnel| {
                let mut row = row([
                    ("id", JsonValue::String(tunnel.id.clone())),
                    (
                        "lifecycle",
                        JsonValue::String(match tunnel.lifecycle() {
                            TunnelLifecycle::Proposed => "proposed".to_owned(),
                            _ => "active".to_owned(),
                        }),
                    ),
                ]);
                if let Some(source) = tunnel.source_drawer_id.as_ref().filter(|id| !hidden_endpoint_ids.contains(*id)) {
                    row.insert("source_drawer_id".to_owned(), JsonValue::String(source.clone()));
                }
                if let Some(target) = tunnel.target_drawer_id.as_ref().filter(|id| !hidden_endpoint_ids.contains(*id)) {
                    row.insert("target_drawer_id".to_owned(), JsonValue::String(target.clone()));
                }
                row
            })
            .collect::<Vec<_>>();

        // Same rule for fact groups: whether a group conflicts is decided over
        // EVERY fact. Filtering first can hide a whole group, or leave one
        // looking consistent because the fact that disagreed was restricted.
        let all_facts = coordinator
            .recall_kg_facts(&admission.estate_handle)
            .map_err(|_| ())?;
        let mut all_facts_by_key = BTreeMap::<(String, String), Vec<_>>::new();
        for fact in &all_facts {
            all_facts_by_key
                .entry((fact.subject.to_lowercase(), fact.predicate.to_lowercase()))
                .or_default()
                .push(fact.object.to_lowercase());
        }
        let all_conflicting_keys = all_facts_by_key
            .into_iter()
            .filter(|(_, objects)| objects.iter().collect::<BTreeSet<_>>().len() > 1)
            .map(|(key, _)| key)
            .collect::<BTreeSet<_>>();
        let total_conflicting_fact_group_count = all_conflicting_keys.len() as i64;
        let facts = all_facts
            .into_iter()
            .filter(|fact| fact.adjective_sensitivity().is_bulk_exportable())
            .collect::<Vec<_>>();
        let mut facts_by_key = BTreeMap::<(String, String), Vec<_>>::new();
        for fact in facts {
            facts_by_key
                .entry((fact.subject.to_lowercase(), fact.predicate.to_lowercase()))
                .or_default()
                .push(fact);
        }
        let visible_conflicting_key_count = facts_by_key
            .iter()
            .filter(|(_, facts)| facts.iter().map(|fact| fact.object.to_lowercase()).collect::<BTreeSet<_>>().len() > 1)
            .count() as i64;
        let conflicting_facts = facts_by_key
            .into_iter()
            .filter(|(_, facts)| facts.iter().map(|fact| fact.object.to_lowercase()).collect::<BTreeSet<_>>().len() > 1)
            .take(20)
            .map(|((subject, predicate), facts)| {
                let mut seen = BTreeSet::new();
                let objects = facts
                    .into_iter()
                    .filter_map(|fact| seen.insert(fact.object.to_lowercase()).then_some(JsonValue::String(fact.object)))
                    .collect::<Vec<_>>();
                row([
                    ("subject", JsonValue::String(subject)),
                    ("predicate", JsonValue::String(predicate)),
                    ("objects", JsonValue::Array(objects)),
                ])
            })
            .collect::<Vec<_>>();

        let withheld_conflicting_fact_group_count =
            total_conflicting_fact_group_count - visible_conflicting_key_count;
        Ok(result(
            request.operation,
            vec![row([
                ("contradicts_tunnels", JsonValue::Array(contradicts_tunnels.into_iter().map(JsonValue::Object).collect())),
                ("conflicting_facts", JsonValue::Array(conflicting_facts.into_iter().map(JsonValue::Object).collect())),
                // Totals cover EVERY contradiction, including rows the caller
                // may not read; the withheld counts say how much of that is
                // redacted. Without them a hidden contradiction is
                // indistinguishable from no contradiction.
                ("total_contradiction_count", JsonValue::Integer(total_contradiction_count)),
                ("total_conflicting_fact_group_count", JsonValue::Integer(total_conflicting_fact_group_count)),
                ("withheld_contradiction_count", JsonValue::Integer(withheld_contradiction_count)),
                ("withheld_conflicting_fact_group_count", JsonValue::Integer(withheld_conflicting_fact_group_count)),
            ])],
        ))
    }

    fn theme_weather(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let weather = run_theme_weather(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            604_800.0,
            admission.now_millis,
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            weather
                .into_iter()
                .map(|weather| {
                    row([
                        ("category", JsonValue::String(weather.category)),
                        ("momentum", JsonValue::Double(weather.momentum)),
                    ])
                })
                .collect(),
        ))
    }

    fn latent_themes(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let themes = run_latent_themes(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            3,
            admission.now_millis,
        )
        .map_err(|_| ())?;
        let loadings = themes
            .loadings
            .into_iter()
            .map(|loading| {
                Ok(JsonValue::Object(row([
                    ("label", JsonValue::String(loading.label)),
                    ("dominantTheme", usize_value(loading.dominant_theme)?),
                ])))
            })
            .collect::<Result<Vec<_>, ()>>()?;
        Ok(result(
            request.operation,
            vec![row([
                ("k", usize_value(themes.k)?),
                ("loadings", JsonValue::Array(loadings)),
            ])],
        ))
    }

    fn drift(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let split_at = parse_iso8601_millis(required_string(request, "splitAt")?).ok_or(())?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = run_drift(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            split_at,
            admission.now_millis,
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            vec![row([
                ("before_count", usize_value(output.before_count)?),
                ("after_count", usize_value(output.after_count)?),
                (
                    "drift",
                    JsonValue::Object(row([
                        (
                            "jensenShannon",
                            JsonValue::Double(output.drift.jensen_shannon as f64),
                        ),
                        (
                            "klDivergence",
                            JsonValue::Double(output.drift.kl_divergence as f64),
                        ),
                    ])),
                ),
            ])],
        ))
    }

    fn trust_synthesis(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let mut frame = RecallFrame::new(Vec::new());
        frame.limit = positive_limit(request, "limit", RESULT_LIMIT)?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = run_trust_grounded_synthesis(
            &coordinator,
            &admission.estate_handle,
            frame,
            None,
            admission.now_millis,
            &std::collections::HashMap::new(),
        )
        .map_err(|_| ())?;
        let context = JsonValue::Object(row([
            ("summary", JsonValue::String(output.context.summary)),
            (
                "patterns",
                JsonValue::Array(
                    output
                        .context
                        .patterns
                        .into_iter()
                        .map(JsonValue::String)
                        .collect(),
                ),
            ),
            (
                "successRate",
                JsonValue::Double(output.context.success_rate as f64),
            ),
            (
                "averageReward",
                JsonValue::Double(output.context.average_reward as f64),
            ),
            (
                "recommendations",
                JsonValue::Array(
                    output
                        .context
                        .recommendations
                        .into_iter()
                        .map(JsonValue::String)
                        .collect(),
                ),
            ),
            (
                "keyInsights",
                JsonValue::Array(
                    output
                        .context
                        .key_insights
                        .into_iter()
                        .map(JsonValue::String)
                        .collect(),
                ),
            ),
        ]));
        Ok(result(
            request.operation,
            vec![row([
                ("context", context),
                (
                    "ranked_ids",
                    JsonValue::Array(
                        output
                            .ranked_ids
                            .into_iter()
                            .map(JsonValue::String)
                            .collect(),
                    ),
                ),
                ("high_trust_count", usize_value(output.high_trust_count)?),
            ])],
        ))
    }

    fn partial_cue(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let anchor_id = required_uuid(request, "anchor_memory_id")?.to_string();
        let limit = positive_limit(request, "limit", 5)?.unwrap_or(5);
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let matches = run_partial_cue_recall(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            &anchor_id,
            CueMode::FeelsLike,
            limit,
            admission.now_millis,
        )
        .map_err(|_| ())?;
        let estate = coordinator
            .estate_for(&admission.estate_handle)
            .map_err(|_| ())?;
        let rows = matches
            .into_iter()
            .map(|matched| {
                let drawer = estate
                    .drawer_by_id(&matched.id)
                    .map_err(|_| ())?
                    .ok_or(())?;
                Ok(row([
                    ("memory_id", JsonValue::String(matched.id)),
                    (
                        "event_time",
                        JsonValue::String(crate::result_composer::iso8601_flex(drawer.event_time)),
                    ),
                    ("score", JsonValue::Double(matched.score)),
                ]))
            })
            .collect::<Result<Vec<_>, ()>>()?;
        Ok(result(request.operation, rows))
    }

    fn anticipate(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let target_kind = content_kind(required_string(request, "targetKind")?)?;
        if target_kind == ContentKind::Dataset {
            return Err(());
        }
        let limit = positive_limit(request, "limit", 5)?.unwrap_or(5);
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let predictions = run_anticipate(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            target_kind.raw_value() as u8,
            limit,
            1,
            admission.now_millis,
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            predictions
                .into_iter()
                .map(|prediction| {
                    row([
                        ("action", JsonValue::Integer(i64::from(prediction.action))),
                        (
                            "success_rate",
                            JsonValue::Double(prediction.success_rate as f64),
                        ),
                        ("count", JsonValue::Integer(i64::from(prediction.count))),
                    ])
                })
                .collect(),
        ))
    }

    fn node_motion(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let memory_uuid = required_uuid(request, "memory_id")?;
        let canonical = memory_uuid.hyphenated().to_string();
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let estate = coordinator
            .estate_for(&admission.estate_handle)
            .map_err(|_| ())?;
        // Both storage spellings. Public v2 ids are canonical lowercase while
        // the estate may hold the native uppercase form, so a single-spelling
        // lookup resolves nothing on an estate written by the other port.
        let (memory_id, drawer) = [canonical.clone(), canonical.to_uppercase()]
            .into_iter()
            .find_map(|spelling| {
                estate
                    .drawer_by_id(&spelling)
                    .ok()
                    .flatten()
                    .map(|drawer| (spelling, drawer))
            })
            .ok_or(())?;
        if drawer.tombstoned_at.is_some()
            || matches!(
                drawer.adjective_sensitivity(),
                AdjectiveSensitivity::Restricted | AdjectiveSensitivity::Secret
            )
        {
            return Err(());
        }
        let events = coordinator
            .audit_events(&admission.estate_handle, None, 50_000)
            .map_err(|_| ())?;
        let entries = events
            .iter()
            .filter(|event| event.row_id.0 == memory_uuid.as_u128())
            .flat_map(bridge_audit_event)
            .collect::<Vec<_>>();
        let row_id = genius_locus_kit::audit::log::EntryUUID(*memory_uuid.as_bytes());
        let motion = neuron_kit::diffusion::node_motion::fold(
            &entries,
            row_id,
            admission.now_millis,
            neuron_kit::diffusion::node_motion::DEFAULT_NODE_LAMBDA,
        );
        let anomaly = neuron_kit::diffusion::node_anomaly::classify(
            &motion,
            neuron_kit::diffusion::node_anomaly::DEFAULT_CHURN_THRESHOLD,
        );
        let anomaly_name = if anomaly.is_churning {
            "churning"
        } else if anomaly.reanchored {
            "reanchored"
        } else {
            "stable"
        };

        Ok(result(
            request.operation,
            vec![row([
                ("row_id", JsonValue::String(memory_id)),
                ("volatility", JsonValue::Double(motion.volatility)),
                ("event_count", usize_value(motion.event_count)?),
                (
                    "last_event_physical_ms",
                    motion
                        .last_event_physical_ms
                        .map(JsonValue::Integer)
                        .unwrap_or(JsonValue::Null),
                ),
                (
                    "anchor_trajectory",
                    JsonValue::Array(
                        motion
                            .anchor_trajectory
                            .iter()
                            .copied()
                            .map(|anchor| usize_value(anchor as usize))
                            .collect::<Result<Vec<_>, ()>>()?,
                    ),
                ),
                ("reanchored", JsonValue::Bool(motion.reanchored())),
                (
                    "current_anchor",
                    anomaly
                        .current_anchor
                        .map(|anchor| usize_value(anchor as usize))
                        .transpose()?
                        .unwrap_or(JsonValue::Null),
                ),
                ("anomaly", JsonValue::String(anomaly_name.to_owned())),
            ])],
        ))
    }

    fn successors(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let wing = required_string(request, "wing")?;
        let anchor_id = required_uuid(request, "anchor_memory_id")?.to_string();
        let limit = positive_limit(request, "limit", RESULT_LIMIT)?.unwrap_or(5);
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let successors = run_tunnel_successor(
            &coordinator,
            &admission.estate_handle,
            wing,
            &anchor_id,
            limit,
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            successors
                .into_iter()
                .map(|successor| {
                    row([
                        ("id", JsonValue::String(successor.id)),
                        (
                            "weight",
                            usize_value(successor.weight).unwrap_or(JsonValue::Null),
                        ),
                    ])
                })
                .collect(),
        ))
    }

    fn comparison_handle(
        coordinator: &EstateCoordinator,
        request: &V2RecallLensRequest,
    ) -> Result<genius_locus_kit::handle::EstateHandle, ()> {
        let comparison_id = required_uuid(request, "comparison_estate_id")?;
        coordinator
            .handles()
            .into_iter()
            .find(|handle| uuid::Uuid::from_bytes(handle.estate_uuid) == comparison_id)
            .ok_or(())
    }

    fn overlap(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let comparison = Self::comparison_handle(&coordinator, request)?;
        let output = run_mind_overlap(
            &coordinator,
            &admission.estate_handle,
            &comparison,
            || RecallFrame::new(Vec::new()),
            admission.now_millis,
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            vec![row([
                ("overlap", JsonValue::Double(output.overlap)),
                ("a_sufficient", JsonValue::Bool(output.a_sufficient)),
                ("b_sufficient", JsonValue::Bool(output.b_sufficient)),
            ])],
        ))
    }

    fn divergence(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let comparison = Self::comparison_handle(&coordinator, request)?;
        let output = run_estate_divergence(
            &coordinator,
            &admission.estate_handle,
            &comparison,
            || RecallFrame::new(Vec::new()),
            admission.now_millis,
            &std::collections::HashMap::new(),
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            vec![row([
                ("a_count", usize_value(output.a_count)?),
                ("b_count", usize_value(output.b_count)?),
                (
                    "divergence",
                    JsonValue::Object(row([
                        (
                            "jensenShannon",
                            JsonValue::Double(output.divergence.jensen_shannon as f64),
                        ),
                        (
                            "klDivergence",
                            JsonValue::Double(output.divergence.kl_divergence as f64),
                        ),
                    ])),
                ),
            ])],
        ))
    }

    fn associations(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        if request.values.contains_key("dataset_id") {
            return Err(());
        }
        let mut frame = RecallFrame::new(Vec::new());
        frame.limit = positive_limit(request, "limit", RESULT_LIMIT)?;
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = run_association_rules(
            &coordinator,
            &admission.estate_handle,
            frame,
            MiningThresholds {
                min_support: 0.0,
                min_confidence: 0.0,
            },
            admission.now_millis,
        )
        .map_err(|_| ())?;
        let rules = output
            .rules
            .into_iter()
            .map(|rule| {
                JsonValue::Object(row([
                    ("antecedent", JsonValue::String(rule.antecedent)),
                    ("consequent", JsonValue::String(rule.consequent)),
                    ("support", JsonValue::Double(rule.support)),
                    ("confidence", JsonValue::Double(rule.confidence)),
                    ("lift", JsonValue::Double(rule.lift)),
                    ("conviction", JsonValue::Double(rule.conviction)),
                    ("leverage", JsonValue::Double(rule.leverage)),
                    (
                        "exemplarDrawerIDs",
                        JsonValue::Array(
                            rule.exemplar_drawer_ids
                                .into_iter()
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                ]))
            })
            .collect();
        Ok(result(
            request.operation,
            vec![row([
                ("rules", JsonValue::Array(rules)),
                ("drawer_count", usize_value(output.drawer_count)?),
                ("label_overflow", JsonValue::Bool(output.label_overflow)),
            ])],
        ))
    }

    fn concepts(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let mut frame = RecallFrame::new(Vec::new());
        frame.limit = positive_limit(request, "recall_limit", RESULT_LIMIT)?;
        let max_concepts = positive_limit(request, "limit", RESULT_LIMIT)?.unwrap_or(20);
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let receipt = run_formal_concepts_receipt(
            &coordinator,
            &admission.estate_handle,
            frame,
            BoundedConceptMiner::new(1, 8, max_concepts),
            admission.now_millis,
        )
        .map_err(|_| ())?;
        let concepts = receipt
            .raw_concepts
            .iter()
            .map(|concept| {
                let extent = concept
                    .extent
                    .iter()
                    .map(|row_id| {
                        receipt
                            .drawer_ids
                            .get(*row_id as usize)
                            .cloned()
                            .map(JsonValue::String)
                            .ok_or(())
                    })
                    .collect::<Result<Vec<_>, ()>>()?;
                Ok(JsonValue::Object(row([
                    (
                        "intent",
                        JsonValue::Array(
                            concept
                                .intent
                                .iter()
                                .map(formal_attribute_value)
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                    ("extentDrawerIDs", JsonValue::Array(extent)),
                    ("support", usize_value(concept.support)?),
                    (
                        "stability",
                        concept
                            .stability
                            .map(JsonValue::Double)
                            .unwrap_or(JsonValue::Null),
                    ),
                ])))
            })
            .collect::<Result<Vec<_>, ()>>()?;
        let covered = ConceptCoverDeltas::covering(
            &receipt
                .raw_concepts
                .iter()
                .take(100)
                .cloned()
                .collect::<Vec<_>>(),
        );
        let cover_deltas = covered
            .cover_deltas
            .into_iter()
            .map(|delta| {
                JsonValue::Object(row([
                    (
                        "lowerIntent",
                        JsonValue::Array(
                            delta
                                .lower_intent
                                .iter()
                                .map(formal_attribute_value)
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                    (
                        "addedAttributes",
                        JsonValue::Array(
                            delta
                                .added_attributes
                                .iter()
                                .map(formal_attribute_value)
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                ]))
            })
            .collect();
        let implications = ConceptImplications::compute(&receipt.context, 200, 4);
        let implication_rows = implications
            .implications
            .into_iter()
            .map(|implication| {
                JsonValue::Object(row([
                    (
                        "premise",
                        JsonValue::Array(
                            implication
                                .premise
                                .iter()
                                .map(formal_attribute_value)
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                    (
                        "conclusion",
                        JsonValue::Array(
                            implication
                                .conclusion
                                .iter()
                                .map(formal_attribute_value)
                                .map(JsonValue::String)
                                .collect(),
                        ),
                    ),
                ]))
            })
            .collect();
        Ok(result(
            request.operation,
            vec![row([
                ("concepts", JsonValue::Array(concepts)),
                ("drawer_count", usize_value(receipt.drawer_ids.len())?),
                ("cover_deltas", JsonValue::Array(cover_deltas)),
                ("implications", JsonValue::Array(implication_rows)),
                (
                    "implications_truncated",
                    JsonValue::Bool(implications.is_truncated),
                ),
            ])],
        ))
    }

    fn apriori(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let limit = positive_limit(request, "limit", RESULT_LIMIT)?.unwrap_or(20);
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let mut output = run_apriori_rules(
            &coordinator,
            &admission.estate_handle,
            AprioriThresholds::new(0.0, 0.0, 1.0, 3),
        )
        .map_err(|_| ())?;
        output.rules.truncate(limit);
        let rules = output
            .rules
            .into_iter()
            .map(|rule| {
                JsonValue::Object(row([
                    (
                        "antecedent",
                        JsonValue::Array(
                            rule.antecedent
                                .into_iter()
                                .map(|item| {
                                    JsonValue::String(format!("{}:{}", item.field, item.value))
                                })
                                .collect(),
                        ),
                    ),
                    (
                        "consequent",
                        JsonValue::String(format!(
                            "{}:{}",
                            rule.consequent.field, rule.consequent.value
                        )),
                    ),
                    ("support", JsonValue::Double(rule.support)),
                    ("confidence", JsonValue::Double(rule.confidence)),
                    ("lift", JsonValue::Double(rule.lift)),
                    (
                        "evidenceCount",
                        usize_value(rule.evidence_count).unwrap_or(JsonValue::Null),
                    ),
                ]))
            })
            .collect();
        Ok(result(
            request.operation,
            vec![row([("rules", JsonValue::Array(rules))])],
        ))
    }

    fn moment(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        // The frozen v2 grammar currently carries comparison_windows as an
        // opaque string.  It has no typed window-array decoder, so only the
        // source-backed empty-comparison form is admitted here.
        if request.values.contains_key("comparison_windows") {
            return Err(());
        }
        let start = parse_iso8601_millis(required_string(request, "windowStart")?).ok_or(())?;
        let end = parse_iso8601_millis(required_string(request, "windowEnd")?).ok_or(())?;
        if start > end {
            return Err(());
        }
        // A window spanning decades scans the entire corpus and exhausts
        // memory. Three years, matching the v1 ceiling, which survived into v2
        // only inside the unreachable v1 dispatch table.
        if end.saturating_sub(start) > MAXIMUM_WINDOW_MILLIS {
            return Err(());
        }
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = run_moment(
            &coordinator,
            &admission.estate_handle,
            (start, end),
            &[],
            admission.now_millis,
        )
        .map_err(|_| ())?;
        let ranking = output
            .result
            .ranking
            .into_iter()
            .map(|rank| {
                Ok(JsonValue::Object(row([(
                    "hamming_distance",
                    usize_value(rank.hamming_distance as usize)?,
                )])))
            })
            .collect::<Result<Vec<_>, ()>>()?;
        Ok(result(
            request.operation,
            vec![row([
                ("window_count", usize_value(output.window_count)?),
                ("ranking", JsonValue::Array(ranking)),
            ])],
        ))
    }

    fn rhythm(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let bit = required_string(request, "bit")?
            .parse::<usize>()
            .map_err(|_| ())?;
        let bucket_seconds = required_string(request, "bucketSeconds")?
            .parse::<i64>()
            .map_err(|_| ())?;
        let bucket_count = required_string(request, "bucketCount")?
            .parse::<usize>()
            .map_err(|_| ())?;
        let ending_at = parse_iso8601_millis(required_string(request, "endingAt")?).ok_or(())?;
        if bit > 255 || bucket_seconds < 1 || bucket_count == 0 {
            return Err(());
        }
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = cognition_kit::rhythm_recipe::run_rhythm_from_estate(
            &coordinator,
            &admission.estate_handle,
            bit,
            bucket_seconds,
            bucket_count,
            ending_at,
            3,
        )
        .map_err(|_| ())?;
        let periods = output
            .periods
            .into_iter()
            .map(|period| {
                Ok(JsonValue::Object(row([
                    (
                        "period_seconds",
                        JsonValue::Integer(period.period_seconds as i64),
                    ),
                    (
                        "relative_magnitude",
                        JsonValue::Double(period.relative_magnitude),
                    ),
                ])))
            })
            .collect::<Result<Vec<_>, ()>>()?;
        Ok(result(
            request.operation,
            vec![row([
                ("bucket_count", usize_value(output.bucket_count)?),
                ("periods", JsonValue::Array(periods)),
            ])],
        ))
    }

    fn precedence(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        let start = parse_iso8601_millis(required_string(request, "windowStart")?).ok_or(())?;
        let end = parse_iso8601_millis(required_string(request, "windowEnd")?).ok_or(())?;
        if start > end {
            return Err(());
        }
        // A window spanning decades scans the entire corpus and exhausts
        // memory. Three years, matching the v1 ceiling, which survived into v2
        // only inside the unreachable v1 dispatch table.
        if end.saturating_sub(start) > MAXIMUM_WINDOW_MILLIS {
            return Err(());
        }
        let target = TemporalFieldCoord::new(
            required_string(request, "targetField")?,
            required_string(request, "targetValue")?,
        );
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let eligible_row_ids = coordinator
            .all_drawers_bounded(&admission.estate_handle, None)
            .map_err(|_| ())?
            .into_iter()
            .filter(|drawer| {
                drawer.event_time >= start
                    && drawer.event_time <= end
                    && !matches!(
                        drawer.adjective_sensitivity(),
                        AdjectiveSensitivity::Restricted | AdjectiveSensitivity::Secret
                    )
            })
            .filter_map(|drawer| {
                uuid::Uuid::parse_str(&drawer.id)
                    .ok()
                    .map(|id| id.as_u128())
            })
            .collect::<std::collections::HashSet<_>>();
        let entries = coordinator
            .audit_events(&admission.estate_handle, None, 50_000)
            .map_err(|_| ())?
            .iter()
            .filter(|event| eligible_row_ids.contains(&event.row_id.0))
            .flat_map(bridge_audit_event)
            .collect::<Vec<_>>();
        let temporal_entries = event_lag_pairs(&entries, start, end);
        let output = run_precedence(&temporal_entries, &target, 5, 128);
        let antecedents = output
            .antecedents
            .into_iter()
            .map(|antecedent| {
                Ok(JsonValue::Object(row([
                    (
                        "source",
                        JsonValue::Object(row([
                            ("fieldPath", JsonValue::String(antecedent.source.field_path)),
                            ("valueRepr", JsonValue::String(antecedent.source.value_repr)),
                        ])),
                    ),
                    (
                        "lag_bucket",
                        JsonValue::Integer(i64::from(antecedent.lag_bucket)),
                    ),
                    ("count", JsonValue::Integer(antecedent.count)),
                ])))
            })
            .collect::<Result<Vec<_>, ()>>()?;
        Ok(result(
            request.operation,
            vec![row([
                ("entry_count", usize_value(output.entry_count)?),
                ("antecedents", JsonValue::Array(antecedents)),
            ])],
        ))
    }

    fn complexity(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        if request.values.contains_key("dataset_id") {
            return Err(());
        }
        let field_a = required_string(request, "fieldA")?;
        let field_b = optional_string(request, "fieldB")?;
        if !["addedBy", "embeddingModelID", "room", "wing"].contains(&field_a)
            || field_b.is_some_and(|field| {
                !["addedBy", "embeddingModelID", "room", "wing"].contains(&field)
            })
        {
            return Err(());
        }
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let output = run_complexity(
            &coordinator,
            &admission.estate_handle,
            RecallFrame::new(Vec::new()),
            field_a,
            field_b,
            admission.now_millis,
        )
        .map_err(|_| ())?;
        Ok(result(
            request.operation,
            vec![row([
                ("total_count", usize_value(output.total_count)?),
                (
                    "result",
                    JsonValue::Object(row([
                        (
                            "entropyA",
                            JsonValue::Double(output.result.entropy_a as f64),
                        ),
                        (
                            "entropyB",
                            output
                                .result
                                .entropy_b
                                .map(|value| JsonValue::Double(value as f64))
                                .unwrap_or(JsonValue::Null),
                        ),
                        (
                            "mutualInformation",
                            output
                                .result
                                .mutual_information
                                .map(|value| JsonValue::Double(value as f64))
                                .unwrap_or(JsonValue::Null),
                        ),
                    ])),
                ),
            ])],
        ))
    }
}

impl V2RecallLensLower for CoordinatorRecallLensLower {
    fn execute(
        &self,
        admission: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, ()> {
        match request.operation {
            V2RecallLensOperation::LensKeystones => self.keystones(admission, request),
            V2RecallLensOperation::LensConstellation => self.constellation(admission, request),
            V2RecallLensOperation::LensFreeAssociation => self.free_association(admission, request),
            V2RecallLensOperation::LensThemeWeather => self.theme_weather(admission, request),
            V2RecallLensOperation::LensLatentThemes => self.latent_themes(admission, request),
            V2RecallLensOperation::LensBias => self.bias(admission, request),
            V2RecallLensOperation::LensDrift => self.drift(admission, request),
            V2RecallLensOperation::LensCohesion => self.cohesion(admission, request),
            V2RecallLensOperation::LensContradiction => self.contradiction(admission, request),
            V2RecallLensOperation::LensTrustSynthesis => self.trust_synthesis(admission, request),
            V2RecallLensOperation::LensPartialCue => self.partial_cue(admission, request),
            V2RecallLensOperation::LensAnticipate => self.anticipate(admission, request),
            V2RecallLensOperation::LensNodeMotion => self.node_motion(admission, request),
            V2RecallLensOperation::LensSuccessors => self.successors(admission, request),
            V2RecallLensOperation::LensOverlap => self.overlap(admission, request),
            V2RecallLensOperation::LensDivergence => self.divergence(admission, request),
            V2RecallLensOperation::LensAssociations => self.associations(admission, request),
            V2RecallLensOperation::LensConcepts => self.concepts(admission, request),
            V2RecallLensOperation::LensApriori => self.apriori(admission, request),
            V2RecallLensOperation::LensMoment => self.moment(admission, request),
            V2RecallLensOperation::LensRhythm => self.rhythm(admission, request),
            V2RecallLensOperation::LensPrecedence => self.precedence(admission, request),
            V2RecallLensOperation::LensComplexity => self.complexity(admission, request),
            _ => Err(()),
        }
    }
}

/// Project the typed lower receipt into the exact operation-specific v2 data
/// schema. The lower rows stay transport-neutral; this is the only wire-shape
/// conversion and it never consumes a v1 result.
pub fn project_data(result: &V2RecallLensResult) -> Result<serde_json::Value, ()> {
    use serde_json::json;
    match result.operation {
        V2RecallLensOperation::LensKeystones => Ok(json!({
            "keystones": result.rows.iter().map(|row| Ok(json!({
                "id": json_value(required_field(row, "memory_id")?)?,
                "centrality": json_value(required_field(row, "centrality")?)?,
            }))).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensConstellation => Ok(json!({
            "communities": result.rows.iter().map(|row| {
                json_value(required_field(row, "memory_ids")?)
            }).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensFreeAssociation => Ok(json!({
            "associations": result.rows.iter().map(|row| Ok(json!({
                "drawerID": json_value(required_field(row, "memory_id")?)?,
                "activation": json_value(required_field(row, "activation")?)?,
            }))).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensThemeWeather => Ok(json!({
            "weather": result.rows.iter().map(|row| Ok(json!({
                "category": json_value(required_field(row, "category")?)?,
                "momentum": json_value(required_field(row, "momentum")?)?,
            }))).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensLatentThemes => {
            let row = one_row(result)?;
            Ok(json!({
                "k": json_value(required_field(row, "k")?)?,
                "loadings": json_value(required_field(row, "loadings")?)?,
            }))
        }
        V2RecallLensOperation::LensBias => {
            let mut biased_for = Vec::new();
            let mut biased_against = Vec::new();
            let mut dismissal = Vec::new();
            let mut learned = Vec::new();
            for row in &result.rows {
                match string_field(row, "kind")? {
                    "for" => biased_for.push(json!({
                        "label": json_value(required_field(row, "label")?)?,
                        "bias": json_value(required_field(row, "bias")?)?,
                    })),
                    "against" => biased_against.push(json!({
                        "label": json_value(required_field(row, "label")?)?,
                        "bias": json_value(required_field(row, "bias")?)?,
                    })),
                    "dismissal" => dismissal.push(json!({
                        "nodeId": json_value(required_field(row, "label")?)?,
                        "rate": json_value(required_field(row, "rate")?)?,
                    })),
                    "learned" => learned.push(json!({
                        "label": json_value(required_field(row, "label")?)?,
                        "strength": json_value(required_field(row, "strength")?)?,
                        "endorsements": json_value(required_field(row, "endorsements")?)?,
                        "dismissals": json_value(required_field(row, "dismissals")?)?,
                    })),
                    _ => return Err(()),
                }
            }
            Ok(json!({
                "biasedFor": biased_for,
                "biasedAgainst": biased_against,
                "dismissal": dismissal,
                "learned": learned,
            }))
        }
        V2RecallLensOperation::LensDrift => {
            let row = one_row(result)?;
            Ok(json!({
                "beforeCount": json_value(required_field(row, "before_count")?)?,
                "afterCount": json_value(required_field(row, "after_count")?)?,
                "drift": json_value(required_field(row, "drift")?)?,
            }))
        }
        V2RecallLensOperation::LensCohesion => {
            let row = one_row(result)?;
            Ok(json!({
                "considered": json_value(required_field(row, "considered")?)?,
                "outliers": json_value(required_field(row, "outlier_memory_ids")?)?,
            }))
        }
        V2RecallLensOperation::LensContradiction => {
            let row = one_row(result)?;
            let JsonValue::Array(tunnels) = required_field(row, "contradicts_tunnels")? else {
                return Err(());
            };
            let contradicts_tunnels = tunnels
                .iter()
                .map(|tunnel| {
                    let JsonValue::Object(tunnel) = tunnel else {
                        return Err(());
                    };
                    let mut output = serde_json::Map::new();
                    output.insert("id".to_owned(), json_value(required_field(tunnel, "id")?)?);
                    output.insert(
                        "lifecycle".to_owned(),
                        json_value(required_field(tunnel, "lifecycle")?)?,
                    );
                    for (source, target) in [
                        ("source_drawer_id", "sourceDrawerId"),
                        ("target_drawer_id", "targetDrawerId"),
                    ] {
                        if let Some(value) = tunnel.get(source) {
                            output.insert(target.to_owned(), json_value(value)?);
                        }
                    }
                    Ok(serde_json::Value::Object(output))
                })
                .collect::<Result<Vec<_>, ()>>()?;
            Ok(json!({
                "contradictsTunnels": contradicts_tunnels,
                "conflictingFacts": json_value(required_field(row, "conflicting_facts")?)?,
                "totalContradictionCount": json_value(required_field(row, "total_contradiction_count")?)?,
                "totalConflictingFactGroupCount": json_value(required_field(row, "total_conflicting_fact_group_count")?)?,
                "withheldContradictionCount": json_value(required_field(row, "withheld_contradiction_count")?)?,
                "withheldConflictingFactGroupCount": json_value(required_field(row, "withheld_conflicting_fact_group_count")?)?,
            }))
        }
        V2RecallLensOperation::LensTrustSynthesis => {
            let row = one_row(result)?;
            Ok(json!({
                "context": json_value(required_field(row, "context")?)?,
                "rankedIDs": json_value(required_field(row, "ranked_ids")?)?,
                "highTrustCount": json_value(required_field(row, "high_trust_count")?)?,
            }))
        }
        V2RecallLensOperation::LensPartialCue => Ok(json!({
            "results": result.rows.iter().map(|row| Ok(json!({
                "id": json_value(required_field(row, "memory_id")?)?,
                "eventTime": json_value(required_field(row, "event_time")?)?,
                "score": json_value(required_field(row, "score")?)?,
            }))).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensAnticipate => Ok(json!({
            "actions": result.rows.iter().map(|row| Ok(json!({
                "action": json_value(required_field(row, "action")?)?,
                "successRate": json_value(required_field(row, "success_rate")?)?,
                "count": json_value(required_field(row, "count")?)?,
            }))).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensNodeMotion => {
            let row = one_row(result)?;
            let mut data = serde_json::Map::new();
            data.insert(
                "rowID".to_owned(),
                json_value(required_field(row, "row_id")?)?,
            );
            data.insert(
                "volatility".to_owned(),
                json_value(required_field(row, "volatility")?)?,
            );
            data.insert(
                "eventCount".to_owned(),
                json_value(required_field(row, "event_count")?)?,
            );
            data.insert(
                "anchorTrajectory".to_owned(),
                json_value(required_field(row, "anchor_trajectory")?)?,
            );
            data.insert(
                "reanchored".to_owned(),
                json_value(required_field(row, "reanchored")?)?,
            );
            data.insert(
                "anomaly".to_owned(),
                json_value(required_field(row, "anomaly")?)?,
            );
            for (source, target) in [
                ("last_event_physical_ms", "lastEventPhysicalMs"),
                ("current_anchor", "currentAnchor"),
            ] {
                let value = required_field(row, source)?;
                if !matches!(value, JsonValue::Null) {
                    data.insert(target.to_owned(), json_value(value)?);
                }
            }
            Ok(serde_json::Value::Object(data))
        }
        V2RecallLensOperation::LensSuccessors => Ok(json!({
            "successors": result.rows.iter().map(|row| Ok(json!({
                "id": json_value(required_field(row, "id")?)?,
                "weight": json_value(required_field(row, "weight")?)?,
            }))).collect::<Result<Vec<_>, ()>>()?,
        })),
        V2RecallLensOperation::LensOverlap => {
            let row = one_row(result)?;
            Ok(json!({
                "overlap": json_value(required_field(row, "overlap")?)?,
                "aSufficient": json_value(required_field(row, "a_sufficient")?)?,
                "bSufficient": json_value(required_field(row, "b_sufficient")?)?,
            }))
        }
        V2RecallLensOperation::LensDivergence => {
            let row = one_row(result)?;
            Ok(json!({
                "aCount": json_value(required_field(row, "a_count")?)?,
                "bCount": json_value(required_field(row, "b_count")?)?,
                "divergence": json_value(required_field(row, "divergence")?)?,
            }))
        }
        V2RecallLensOperation::LensAssociations => {
            let row = one_row(result)?;
            Ok(json!({
                "rules": json_value(required_field(row, "rules")?)?,
                "drawerCount": json_value(required_field(row, "drawer_count")?)?,
                "labelOverflow": json_value(required_field(row, "label_overflow")?)?,
            }))
        }
        V2RecallLensOperation::LensConcepts => {
            let row = one_row(result)?;
            let JsonValue::Array(concept_rows) = required_field(row, "concepts")? else {
                return Err(());
            };
            let concepts = concept_rows
                .iter()
                .map(|concept| {
                    let JsonValue::Object(concept) = concept else {
                        return Err(());
                    };
                    let mut output = serde_json::Map::new();
                    output.insert(
                        "intent".to_owned(),
                        json_value(required_field(concept, "intent")?)?,
                    );
                    output.insert(
                        "extentDrawerIDs".to_owned(),
                        json_value(required_field(concept, "extentDrawerIDs")?)?,
                    );
                    output.insert(
                        "support".to_owned(),
                        json_value(required_field(concept, "support")?)?,
                    );
                    let stability = required_field(concept, "stability")?;
                    if !matches!(stability, JsonValue::Null) {
                        output.insert("stability".to_owned(), json_value(stability)?);
                    }
                    Ok(serde_json::Value::Object(output))
                })
                .collect::<Result<Vec<_>, ()>>()?;
            Ok(json!({
                "concepts": concepts,
                "drawerCount": json_value(required_field(row, "drawer_count")?)?,
                "coverDeltas": json_value(required_field(row, "cover_deltas")?)?,
                "implications": json_value(required_field(row, "implications")?)?,
                "implicationsTruncated": json_value(required_field(row, "implications_truncated")?)?,
            }))
        }
        V2RecallLensOperation::LensApriori => {
            let row = one_row(result)?;
            Ok(json!({ "rules": json_value(required_field(row, "rules")?)? }))
        }
        V2RecallLensOperation::LensMoment => {
            let row = one_row(result)?;
            Ok(json!({
                "windowCount": json_value(required_field(row, "window_count")?)?,
                "ranking": json_value(required_field(row, "ranking")?)?,
            }))
        }
        V2RecallLensOperation::LensRhythm => {
            let row = one_row(result)?;
            Ok(json!({
                "bucketCount": json_value(required_field(row, "bucket_count")?)?,
                "periods": json_value(required_field(row, "periods")?)?,
            }))
        }
        V2RecallLensOperation::LensPrecedence => {
            let row = one_row(result)?;
            Ok(json!({
                "entryCount": json_value(required_field(row, "entry_count")?)?,
                "antecedents": json_value(required_field(row, "antecedents")?)?,
            }))
        }
        V2RecallLensOperation::LensComplexity => {
            let row = one_row(result)?;
            let result_value = required_field(row, "result")?;
            let JsonValue::Object(result_row) = result_value else {
                return Err(());
            };
            let mut metrics = serde_json::Map::new();
            metrics.insert(
                "entropyA".to_owned(),
                json_value(required_field(result_row, "entropyA")?)?,
            );
            for (source, target) in [
                ("entropyB", "entropyB"),
                ("mutualInformation", "mutualInformation"),
            ] {
                let value = required_field(result_row, source)?;
                if !matches!(value, JsonValue::Null) {
                    metrics.insert(target.to_owned(), json_value(value)?);
                }
            }
            Ok(json!({
                "totalCount": json_value(required_field(row, "total_count")?)?,
                "result": serde_json::Value::Object(metrics),
            }))
        }
        _ => Err(()),
    }
}

fn one_row(result: &V2RecallLensResult) -> Result<&BTreeMap<String, JsonValue>, ()> {
    result
        .rows
        .first()
        .filter(|_| result.rows.len() == 1)
        .ok_or(())
}

fn required_field<'a>(
    row: &'a BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<&'a JsonValue, ()> {
    row.get(key).ok_or(())
}

fn string_field<'a>(row: &'a BTreeMap<String, JsonValue>, key: &str) -> Result<&'a str, ()> {
    match required_field(row, key)? {
        JsonValue::String(value) => Ok(value),
        _ => Err(()),
    }
}

fn json_value(value: &JsonValue) -> Result<serde_json::Value, ()> {
    serde_json::to_value(value).map_err(|_| ())
}

fn result(
    operation: V2RecallLensOperation,
    rows: Vec<BTreeMap<String, JsonValue>>,
) -> V2RecallLensResult {
    V2RecallLensResult { operation, rows }
}

fn row<const N: usize>(fields: [(&str, JsonValue); N]) -> BTreeMap<String, JsonValue> {
    fields
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect()
}

fn required_string<'a>(request: &'a V2RecallLensRequest, key: &str) -> Result<&'a str, ()> {
    match request.values.get(key) {
        Some(V2RecallLensValue::String(value)) => Ok(value),
        _ => Err(()),
    }
}

fn required_uuid(request: &V2RecallLensRequest, key: &str) -> Result<uuid::Uuid, ()> {
    match request.values.get(key) {
        Some(V2RecallLensValue::Uuid(value)) => Ok(*value),
        _ => Err(()),
    }
}

fn optional_string<'a>(request: &'a V2RecallLensRequest, key: &str) -> Result<Option<&'a str>, ()> {
    match request.values.get(key) {
        None => Ok(None),
        Some(V2RecallLensValue::String(value)) => Ok(Some(value)),
        _ => Err(()),
    }
}

fn formal_attribute_value(attribute: &FormalAttribute) -> String {
    format!(
        "{}.{}={}",
        attribute.namespace, attribute.key, attribute.value
    )
}

fn string_limit(
    request: &V2RecallLensRequest,
    key: &str,
    default: usize,
    ceiling: usize,
) -> Result<usize, ()> {
    let Some(value) = request.values.get(key) else {
        return Ok(default);
    };
    let V2RecallLensValue::String(value) = value else {
        return Err(());
    };
    let value = value.parse::<usize>().map_err(|_| ())?;
    if value == 0 {
        return Err(());
    }
    Ok(value.min(ceiling))
}

fn positive_limit(
    request: &V2RecallLensRequest,
    key: &str,
    ceiling: usize,
) -> Result<Option<usize>, ()> {
    match request.values.get(key) {
        None => Ok(None),
        Some(V2RecallLensValue::Integer(value)) if *value >= 1 => Ok(Some((*value).min(ceiling))),
        _ => Err(()),
    }
}

fn content_kind(value: &str) -> Result<ContentKind, ()> {
    match value {
        "prose" => Ok(ContentKind::Prose),
        "code" => Ok(ContentKind::Code),
        "transcript" => Ok(ContentKind::Transcript),
        "list" => Ok(ContentKind::List),
        "structuredJSON" => Ok(ContentKind::StructuredJson),
        "imageCaption" => Ok(ContentKind::ImageCaption),
        "fingerprintOnly" => Ok(ContentKind::FingerprintOnly),
        "dataset" => Ok(ContentKind::Dataset),
        _ => Err(()),
    }
}

/// Parse the frozen v2 ISO8601 UTC subset directly to the epoch-millisecond
/// lower-engine value. This is argument decoding, not a v1 tool invocation.
fn parse_iso8601_millis(value: &str) -> Option<i64> {
    let value = value
        .trim_end_matches('Z')
        .trim_end_matches("+00:00")
        .trim_end_matches("+0000");
    let (value, millis) = if let Some(position) = value.rfind('.') {
        let fraction: String = value[position + 1..].chars().take(3).collect();
        let mut millis: i64 = fraction.parse().ok()?;
        for _ in fraction.len()..3 {
            millis *= 10;
        }
        (&value[..position], millis)
    } else {
        (value, 0)
    };
    let (date, time) = value.split_once('T')?;
    let mut date = date.split('-').map(str::parse::<i64>);
    let (year, month, day) = (date.next()?.ok()?, date.next()?.ok()?, date.next()?.ok()?);
    if date.next().is_some() {
        return None;
    }
    let mut time = time.split(':').map(str::parse::<i64>);
    let (hour, minute, second) = (time.next()?.ok()?, time.next()?.ok()?, time.next()?.ok()?);
    if time.next().is_some()
        || !(0..24).contains(&hour)
        || !(0..60).contains(&minute)
        || !(0..60).contains(&second)
    {
        return None;
    }
    let days = days_from_ymd(year, month, day)?;
    days.checked_mul(86_400)?
        .checked_add(hour.checked_mul(3_600)?)?
        .checked_add(minute.checked_mul(60)?)?
        .checked_add(second)?
        .checked_mul(1_000)?
        .checked_add(millis)
}

fn days_from_ymd(year: i64, month: i64, day: i64) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let year = if month <= 2 { year - 1 } else { year };
    let month = if month <= 2 { month + 9 } else { month - 3 };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

fn reference(request: &V2RecallLensRequest) -> Result<Vec<(String, f64)>, ()> {
    let Some(value) = request.values.get("reference") else {
        return Ok(Vec::new());
    };
    let V2RecallLensValue::Array(entries) = value else {
        return Err(());
    };
    entries
        .iter()
        .map(|entry| {
            let JsonValue::Object(entry) = entry else {
                return Err(());
            };
            let Some(JsonValue::String(label)) = entry.get("label") else {
                return Err(());
            };
            let Some(mass) = entry.get("mass").and_then(JsonValue::as_f64) else {
                return Err(());
            };
            Ok((label.clone(), mass))
        })
        .collect()
}

fn usize_value(value: usize) -> Result<JsonValue, ()> {
    i64::try_from(value).map(JsonValue::Integer).map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::estate_registry::EstateRegistry;

    #[test]
    fn contradiction_lower_reads_the_selected_estate_without_a_v1_runner() {
        let registry = EstateRegistry::new_inmemory();
        let estate_handle = registry.default.handle.clone();
        let admission = V2RecallLensAdmission {
            estate_id: uuid::Uuid::from_bytes(estate_handle.estate_uuid),
            estate_handle,
            caller_binding: "test-caller".to_owned(),
            authorization_generation: "test-generation".to_owned(),
            now_millis: 1_700_000_000_000,
        };
        let request = V2RecallLensRequest {
            operation: V2RecallLensOperation::LensContradiction,
            estate_id: None,
            values: BTreeMap::new(),
        };

        let lower = CoordinatorRecallLensLower::new(Arc::clone(&registry.default.coord));
        let result = lower.execute(&admission, &request).expect("empty selected estate");

        assert_eq!(
            project_data(&result),
            Ok(serde_json::json!({
                "contradictsTunnels": [],
                "conflictingFacts": [],
                // An empty estate reports zero of everything, INCLUDING the
                // withheld counts, so "none" is stated rather than inferred.
                "totalContradictionCount": 0,
                "totalConflictingFactGroupCount": 0,
                "withheldContradictionCount": 0,
                "withheldConflictingFactGroupCount": 0,
            }))
        );
    }

    #[test]
    fn string_lens_limits_keep_v2_grammar_and_lower_engine_bounds() {
        let mut values = BTreeMap::new();
        values.insert(
            "topK".to_owned(),
            V2RecallLensValue::String("900".to_owned()),
        );
        values.insert(
            "walkLength".to_owned(),
            V2RecallLensValue::String("100001".to_owned()),
        );
        let request = V2RecallLensRequest {
            operation: V2RecallLensOperation::LensKeystones,
            estate_id: None,
            values,
        };

        assert_eq!(
            string_limit(&request, "topK", 5, RESULT_LIMIT),
            Ok(RESULT_LIMIT)
        );
        assert_eq!(
            string_limit(&request, "walkLength", 10_000, WALK_LENGTH_LIMIT),
            Ok(WALK_LENGTH_LIMIT)
        );
    }

    #[test]
    fn bias_reference_stays_typed_until_the_lower_engine_receives_it() {
        let mut reference_entry = BTreeMap::new();
        reference_entry.insert("label".to_owned(), JsonValue::String("study".to_owned()));
        reference_entry.insert("mass".to_owned(), JsonValue::Double(0.75));
        let request = V2RecallLensRequest {
            operation: V2RecallLensOperation::LensBias,
            estate_id: None,
            values: BTreeMap::from([(
                "reference".to_owned(),
                V2RecallLensValue::Array(vec![JsonValue::Object(reference_entry)]),
            )]),
        };

        assert_eq!(reference(&request), Ok(vec![("study".to_owned(), 0.75)]));
    }

    #[test]
    fn contradiction_projection_uses_the_frozen_camel_case_schema_without_text() {
        let result = result(
            V2RecallLensOperation::LensContradiction,
            vec![row([
                (
                    "contradicts_tunnels",
                    JsonValue::Array(vec![JsonValue::Object(row([
                        ("id", JsonValue::String("tunnel-1".to_owned())),
                        ("source_drawer_id", JsonValue::String("memory-a".to_owned())),
                        ("target_drawer_id", JsonValue::String("memory-b".to_owned())),
                        ("lifecycle", JsonValue::String("proposed".to_owned())),
                    ]))]),
                ),
                (
                    "conflicting_facts",
                    JsonValue::Array(vec![JsonValue::Object(row([
                        ("subject", JsonValue::String("project".to_owned())),
                        ("predicate", JsonValue::String("status".to_owned())),
                        (
                            "objects",
                            JsonValue::Array(vec![
                                JsonValue::String("green".to_owned()),
                                JsonValue::String("red".to_owned()),
                            ]),
                        ),
                    ]))]),
                ),
                // The tallies travel with the row: the projection requires
                // them, because a payload without them cannot say whether a
                // contradiction was withheld.
                ("total_contradiction_count", JsonValue::Integer(1)),
                ("total_conflicting_fact_group_count", JsonValue::Integer(1)),
                ("withheld_contradiction_count", JsonValue::Integer(0)),
                ("withheld_conflicting_fact_group_count", JsonValue::Integer(0)),
            ])],
        );

        assert_eq!(
            project_data(&result),
            Ok(serde_json::json!({
                "contradictsTunnels": [{
                    "id": "tunnel-1",
                    "sourceDrawerId": "memory-a",
                    "targetDrawerId": "memory-b",
                    "lifecycle": "proposed",
                }],
                "conflictingFacts": [{
                    "subject": "project",
                    "predicate": "status",
                    "objects": ["green", "red"],
                }],
                // Both rows are visible in this fixture, so the totals match
                // the emitted rows and nothing is withheld.
                "totalContradictionCount": 1,
                "totalConflictingFactGroupCount": 1,
                "withheldContradictionCount": 0,
                "withheldConflictingFactGroupCount": 0,
            }))
        );
    }

    #[test]
    fn cohesion_projection_has_only_typed_summary_fields() {
        let projected = row([
            ("considered", JsonValue::Integer(4)),
            (
                "outlier_memory_ids",
                JsonValue::Array(vec![JsonValue::String("memory-1".to_owned())]),
            ),
        ]);

        assert_eq!(projected.get("considered"), Some(&JsonValue::Integer(4)));
        assert!(matches!(
            projected.get("outlier_memory_ids"),
            Some(JsonValue::Array(values)) if values == &vec![JsonValue::String("memory-1".to_owned())]
        ));
        assert!(!projected.contains_key("text"));
        assert!(!projected.contains_key("content"));

        let result = V2RecallLensResult {
            operation: V2RecallLensOperation::LensCohesion,
            rows: vec![projected],
        };
        assert_eq!(
            project_data(&result),
            Ok(serde_json::json!({"considered":4,"outliers":["memory-1"]}))
        );
    }

    #[test]
    fn concepts_projection_keeps_structural_receipt_fields() {
        let result = V2RecallLensResult {
            operation: V2RecallLensOperation::LensConcepts,
            rows: vec![row([
                (
                    "concepts",
                    JsonValue::Array(vec![JsonValue::Object(row([
                        (
                            "intent",
                            JsonValue::Array(vec![JsonValue::String(
                                "locus.kind=prose".to_owned(),
                            )]),
                        ),
                        (
                            "extentDrawerIDs",
                            JsonValue::Array(vec![JsonValue::String("memory-1".to_owned())]),
                        ),
                        ("support", JsonValue::Integer(1)),
                        ("stability", JsonValue::Null),
                    ]))]),
                ),
                ("drawer_count", JsonValue::Integer(1)),
                (
                    "cover_deltas",
                    JsonValue::Array(vec![JsonValue::Object(row([
                        (
                            "lowerIntent",
                            JsonValue::Array(vec![JsonValue::String(
                                "locus.kind=prose".to_owned(),
                            )]),
                        ),
                        (
                            "addedAttributes",
                            JsonValue::Array(vec![JsonValue::String(
                                "locus.room=study".to_owned(),
                            )]),
                        ),
                    ]))]),
                ),
                ("implications", JsonValue::Array(vec![])),
                ("implications_truncated", JsonValue::Bool(false)),
            ])],
        };

        assert_eq!(
            project_data(&result),
            Ok(serde_json::json!({
                "concepts":[{"intent":["locus.kind=prose"],"extentDrawerIDs":["memory-1"],"support":1}],
                "drawerCount":1,
                "coverDeltas":[{"lowerIntent":["locus.kind=prose"],"addedAttributes":["locus.room=study"]}],
                "implications":[],
                "implicationsTruncated":false
            }))
        );
    }

    #[test]
    fn added_lower_projections_keep_the_frozen_operation_schemas() {
        let theme_weather = V2RecallLensResult {
            operation: V2RecallLensOperation::LensThemeWeather,
            rows: vec![row([
                ("category", JsonValue::String("study".to_owned())),
                ("momentum", JsonValue::Double(0.5)),
            ])],
        };
        assert_eq!(
            project_data(&theme_weather),
            Ok(serde_json::json!({"weather":[{"category":"study","momentum":0.5}]}))
        );

        let latent_themes = V2RecallLensResult {
            operation: V2RecallLensOperation::LensLatentThemes,
            rows: vec![row([
                ("k", JsonValue::Integer(1)),
                (
                    "loadings",
                    JsonValue::Array(vec![JsonValue::Object(row([
                        ("label", JsonValue::String("room:study".to_owned())),
                        ("dominantTheme", JsonValue::Integer(0)),
                    ]))]),
                ),
            ])],
        };
        assert_eq!(
            project_data(&latent_themes),
            Ok(serde_json::json!({"k":1,"loadings":[{"label":"room:study","dominantTheme":0}]}))
        );

        let drift = V2RecallLensResult {
            operation: V2RecallLensOperation::LensDrift,
            rows: vec![row([
                ("before_count", JsonValue::Integer(2)),
                ("after_count", JsonValue::Integer(3)),
                (
                    "drift",
                    JsonValue::Object(row([
                        ("jensenShannon", JsonValue::Double(0.25)),
                        ("klDivergence", JsonValue::Double(0.5)),
                    ])),
                ),
            ])],
        };
        assert_eq!(
            project_data(&drift),
            Ok(
                serde_json::json!({"beforeCount":2,"afterCount":3,"drift":{"jensenShannon":0.25,"klDivergence":0.5}})
            )
        );

        let trust = V2RecallLensResult {
            operation: V2RecallLensOperation::LensTrustSynthesis,
            rows: vec![row([
                (
                    "context",
                    JsonValue::Object(row([
                        ("summary", JsonValue::String("summary".to_owned())),
                        ("patterns", JsonValue::Array(vec![])),
                        ("successRate", JsonValue::Double(1.0)),
                        ("averageReward", JsonValue::Double(0.0)),
                        ("recommendations", JsonValue::Array(vec![])),
                        ("keyInsights", JsonValue::Array(vec![])),
                    ])),
                ),
                (
                    "ranked_ids",
                    JsonValue::Array(vec![JsonValue::String("memory-1".to_owned())]),
                ),
                ("high_trust_count", JsonValue::Integer(1)),
            ])],
        };
        assert_eq!(
            project_data(&trust),
            Ok(
                serde_json::json!({"context":{"summary":"summary","patterns":[],"successRate":1.0,"averageReward":0.0,"recommendations":[],"keyInsights":[]},"rankedIDs":["memory-1"],"highTrustCount":1})
            )
        );

        let partial_cue = V2RecallLensResult {
            operation: V2RecallLensOperation::LensPartialCue,
            rows: vec![row([
                ("memory_id", JsonValue::String("memory-2".to_owned())),
                (
                    "event_time",
                    JsonValue::String("2026-09-08T00:00:00Z".to_owned()),
                ),
                ("score", JsonValue::Double(0.75)),
            ])],
        };
        assert_eq!(
            project_data(&partial_cue),
            Ok(
                serde_json::json!({"results":[{"id":"memory-2","eventTime":"2026-09-08T00:00:00Z","score":0.75}]})
            )
        );

        let anticipate = V2RecallLensResult {
            operation: V2RecallLensOperation::LensAnticipate,
            rows: vec![row([
                ("action", JsonValue::Integer(1)),
                ("success_rate", JsonValue::Double(0.8)),
                ("count", JsonValue::Integer(4)),
            ])],
        };
        assert_eq!(
            project_data(&anticipate),
            Ok(serde_json::json!({"actions":[{"action":1,"successRate":0.8,"count":4}]}))
        );
    }

    #[test]
    fn drift_timestamp_and_anticipate_kind_stay_in_the_typed_lane() {
        assert_eq!(
            parse_iso8601_millis("2026-09-08T00:00:00.125Z"),
            Some(1_788_825_600_125)
        );
        assert_eq!(content_kind("code"), Ok(ContentKind::Code));
        assert_eq!(content_kind("unknown"), Err(()));
    }
}
