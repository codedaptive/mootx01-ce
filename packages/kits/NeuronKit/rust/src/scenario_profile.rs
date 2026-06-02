//! ScenarioProfile Rust version. Persisted preference signal alongside a
//! tournament outcome per NEURONKIT_SPEC § 4.6, minus the
//! `tournament_report` field per Mission Known Ambiguity 2 (the spec
//! type `TournamentReport` references `BranchHandle`, which does not
//! exist in either version today). The field returns in the tournament
//! mission.
//!
//! Bit-identical to the Swift version over shared JSON conformance
//! vectors; field names map kebab-case to snake_case per Rust
//! conventions.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Mirror of Swift `ScenarioProfile`. `tournament_report` is
/// deliberately absent per Mission Known Ambiguity 2.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScenarioProfile {
    pub profile_id: String,
    pub name: String,
    /// Spec `[String: Any]` narrowed to `[String: String]` for
    /// Codable round-trip. Callers serialise structured data as
    /// JSON-encoded strings.
    pub framing_parameters: BTreeMap<String, String>,
    pub scoring_breakdown: BTreeMap<String, f32>,
    pub preference_weights: BTreeMap<String, f32>,
    /// ISO8601 wall-clock; the caller supplies it (deterministic
    /// time discipline — engines do not call clocks).
    pub created_at: String,
    pub training_eligible: bool,
}

impl ScenarioProfile {
    pub fn new(
        profile_id: String,
        name: String,
        framing_parameters: BTreeMap<String, String>,
        scoring_breakdown: BTreeMap<String, f32>,
        preference_weights: BTreeMap<String, f32>,
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
        let mut scoring: BTreeMap<String, f32> = BTreeMap::new();
        scoring.insert("averageReward".to_string(), 0.42);
        scoring.insert("proposalAcceptanceRate".to_string(), 0.61);
        let mut weights: BTreeMap<String, f32> = BTreeMap::new();
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
    fn tournament_report_field_deferred() {
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
        assert!(!json.contains("tournament_report"));
        assert!(!json.contains("tournamentReport"));
        assert!(!json.contains("TournamentReport"));
    }
}
