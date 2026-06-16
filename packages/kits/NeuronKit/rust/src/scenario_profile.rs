//! ScenarioProfile Rust version. Persisted preference signal alongside a
//! tournament outcome per NEURONKIT_SPEC § 4.6.
//!
//! `tournament_report` is a runtime-only field: it is excluded from
//! JSON serialisation via `#[serde(skip)]`. The wire shape therefore
//! never contains the key, matching the Swift CodingKeys exclusion.
//! The field is always `None` after deserialisation; callers that build
//! a ScenarioProfile from a live tournament populate it at construction
//! time.
//!
//! Wire parity with the Swift version: the JSON keys are the Swift
//! Codable camelCase vocabulary (serde rename_all + an explicit
//! "profileID" rename — the house rule set by the catalog descriptors:
//! Swift Codable camelCase is the wire vocabulary, Rust conforms via
//! serde renames). Sorted-keys encodings of the same field values are
//! byte-identical across the versions, asserted by the shared-artifact
//! conformance gate (scenario_profile section, canonicalJson).

use crate::tournament_live::TournamentReport;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Mirror of Swift `ScenarioProfile`. `tournament_report` is a
/// runtime-only advisory field excluded from JSON (see module doc).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScenarioProfile {
    /// Swift's property is `profileID` (capital ID) — rename_all would
    /// emit `profileId`, so the key is pinned explicitly.
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub name: String,
    /// Spec `[String: Any]` narrowed to `[String: String]` for
    /// Codable round-trip. Callers serialise structured data as
    /// JSON-encoded strings.
    pub framing_parameters: BTreeMap<String, String>,
    pub scoring_breakdown: BTreeMap<String, f64>,
    pub preference_weights: BTreeMap<String, f64>,
    /// ISO8601 wall-clock; the caller supplies it (deterministic
    /// time discipline — engines do not call clocks).
    pub created_at: String,
    pub training_eligible: bool,
    /// Advisory tournament outcome attached at profile-save time
    /// (NEURONKIT_SPEC § 4.6). Excluded from JSON serialisation via
    /// `#[serde(skip)]` — `TournamentReport` is not Serialize-able in
    /// a stable cross-version form and is advisory only. Always `None`
    /// after deserialisation; populated by `saveScenarioProfile` at
    /// the moment of creation.
    #[serde(skip)]
    pub tournament_report: Option<TournamentReport>,
}

impl ScenarioProfile {
    pub fn new(
        profile_id: String,
        name: String,
        framing_parameters: BTreeMap<String, String>,
        scoring_breakdown: BTreeMap<String, f64>,
        preference_weights: BTreeMap<String, f64>,
        created_at: String,
        training_eligible: bool,
    ) -> Self {
        Self {
            profile_id,
            name,
            framing_parameters,
            scoring_breakdown,
            preference_weights,
            created_at,
            training_eligible,
            tournament_report: None,
        }
    }

    /// Construct a ScenarioProfile with an attached `TournamentReport`.
    /// Used by `saveScenarioProfile` when a live tournament result is
    /// available. The report is runtime-only and is not persisted.
    #[allow(clippy::too_many_arguments)]
    pub fn with_report(
        profile_id: String,
        name: String,
        framing_parameters: BTreeMap<String, String>,
        scoring_breakdown: BTreeMap<String, f64>,
        preference_weights: BTreeMap<String, f64>,
        created_at: String,
        training_eligible: bool,
        tournament_report: TournamentReport,
    ) -> Self {
        Self {
            profile_id,
            name,
            framing_parameters,
            scoring_breakdown,
            preference_weights,
            created_at,
            training_eligible,
            tournament_report: Some(tournament_report),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_json_identically() {
        let mut framing: BTreeMap<String, String> = BTreeMap::new();
        framing.insert("focus".to_string(), "P0".to_string());
        framing.insert("horizon".to_string(), "1d".to_string());
        let mut scoring: BTreeMap<String, f64> = BTreeMap::new();
        scoring.insert("averageReward".to_string(), 0.42);
        scoring.insert("proposalAcceptanceRate".to_string(), 0.61);
        let mut weights: BTreeMap<String, f64> = BTreeMap::new();
        weights.insert("averageReward".to_string(), 0.5);
        weights.insert("proposalAcceptanceRate".to_string(), 0.5);

        let original = ScenarioProfile::new(
            "12345678-1234-1234-1234-123456789012".to_string(),
            "morning planning".to_string(),
            framing,
            scoring,
            weights,
            "2023-11-14T22:13:20Z".to_string(),
            true,
        );

        let data = serde_json::to_string(&original).unwrap();
        let decoded: ScenarioProfile = serde_json::from_str(&data).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn tournament_report_runtime_only_not_in_json() {
        // `tournament_report` is `#[serde(skip)]` — it must never appear
        // in the JSON wire shape, matching the Swift CodingKeys exclusion.
        let p = ScenarioProfile::new(
            "00000000-0000-0000-0000-000000000000".to_string(),
            "y".to_string(),
            BTreeMap::new(),
            BTreeMap::new(),
            BTreeMap::new(),
            "1970-01-01T00:00:00Z".to_string(),
            false,
        );
        let json = serde_json::to_string(&p).unwrap();
        assert!(!json.contains("tournament_report"), "serde(skip) must hide field: {json}");
        assert!(!json.contains("tournamentReport"), "camelCase variant absent: {json}");
        assert!(!json.contains("TournamentReport"), "type name absent: {json}");
    }

    #[test]
    fn tournament_report_field_present_in_memory() {
        use crate::tournament_live::TournamentReport;
        // The field is live — `with_report` populates it at creation time.
        let report = TournamentReport {
            winner: None,
            ranking: vec![],
            disqualified: vec![],
            evaluated_at: 0,
        };
        let p = ScenarioProfile::with_report(
            "00000000-0000-0000-0000-000000000000".to_string(),
            "z".to_string(),
            BTreeMap::new(),
            BTreeMap::new(),
            BTreeMap::new(),
            "1970-01-01T00:00:00Z".to_string(),
            false,
            report,
        );
        assert!(p.tournament_report.is_some(), "report must be populated");
        // JSON still omits it.
        let json = serde_json::to_string(&p).unwrap();
        assert!(!json.contains("tournament_report"), "serde(skip) must hide field: {json}");
    }

    // The wire keys are the Swift Codable camelCase vocabulary (with the
    // explicit profileID spelling) — never the Rust field names.
    #[test]
    fn wire_keys_are_swift_codable_camel_case() {
        let p = ScenarioProfile::new(
            "00000000-0000-0000-0000-000000000000".to_string(),
            "y".to_string(),
            BTreeMap::new(),
            BTreeMap::new(),
            BTreeMap::new(),
            "1970-01-01T00:00:00Z".to_string(),
            false,
        );
        let json = serde_json::to_string(&p).unwrap();
        for key in [
            "\"profileID\"",
            "\"framingParameters\"",
            "\"scoringBreakdown\"",
            "\"preferenceWeights\"",
            "\"createdAt\"",
            "\"trainingEligible\"",
        ] {
            assert!(json.contains(key), "missing wire key {key}: {json}");
        }
        assert!(!json.contains("profile_id"));
        assert!(!json.contains("created_at"));
    }
}
