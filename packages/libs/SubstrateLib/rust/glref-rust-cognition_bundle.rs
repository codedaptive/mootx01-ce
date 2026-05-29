// cognition_bundle.rs
//
// Portable cognition bundle per cookbook § 13. Mirror of
// glref-swift-PortableCognitionBundle.swift.
//
// Persisted, exportable, importable representation of an estate's
// cognition tier: tournament weights, ranking weights, privacy
// ledger, RecallTrace summary, preferred pipelines, lexicon.

use std::collections::HashMap;
use crate::hlc::HLC;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TournamentWeights {
    pub lattice: f32,
    pub fingerprint: f32,
    pub temporal: f32,
    pub bitmap: f32,
    pub keystone: f32,
    pub latent_factor: f32,
}

impl Default for TournamentWeights {
    fn default() -> Self {
        Self {
            lattice: 0.25, fingerprint: 0.25,
            temporal: 0.15, bitmap: 0.15,
            keystone: 0.10, latent_factor: 0.10,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CompositeDistanceWeights {
    pub lattice: f32,
    pub fingerprint: f32,
    pub temporal: f32,
    pub bitmap: f32,
}

impl Default for CompositeDistanceWeights {
    fn default() -> Self {
        Self { lattice: 0.4, fingerprint: 0.4, temporal: 0.1, bitmap: 0.1 }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RecallTraceSummary {
    pub bins: HashMap<String, u32>,
    pub avg_confidence: HashMap<String, f32>,
    pub avg_user_accept: HashMap<String, f32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreferredPipeline {
    pub intent_tag: String,
    pub primitive_chain: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LexiconEntry {
    pub name: String,
    pub bitmap_column: String,   // "adjective" | "operational" | "provenance"
    pub field_index: u8,
    pub value: u8,
}

#[derive(Debug, Clone)]
pub struct PortableCognitionBundle {
    pub estate_uuid: [u8; 16],
    pub bundle_version: u32,
    pub generated_at: HLC,
    pub tournament_weights: TournamentWeights,
    pub ranking_weights: CompositeDistanceWeights,
    pub privacy_ledger: HashMap<[u8; 16], (f64, f64)>,
    pub recall_trace_summary: RecallTraceSummary,
    pub preferred_pipelines: Vec<PreferredPipeline>,
    pub lexicon: Vec<LexiconEntry>,
}

impl PortableCognitionBundle {
    pub fn new(estate_uuid: [u8; 16], bundle_version: u32, generated_at: HLC) -> Self {
        Self {
            estate_uuid,
            bundle_version,
            generated_at,
            tournament_weights: TournamentWeights::default(),
            ranking_weights: CompositeDistanceWeights::default(),
            privacy_ledger: HashMap::new(),
            recall_trace_summary: RecallTraceSummary::default(),
            preferred_pipelines: Vec::new(),
            lexicon: Vec::new(),
        }
    }

    /// Text serialization (TOML-equivalent).
    pub fn to_text(&self) -> String {
        let mut out = String::new();
        out.push_str("# GeniusLocus Portable Cognition Bundle\n");
        out.push_str(&format!("estate_uuid = \"{}\"\n",
            self.estate_uuid.iter().map(|b| format!("{:02x}", b)).collect::<String>()));
        out.push_str(&format!("bundle_version = {}\n", self.bundle_version));
        out.push_str(&format!("generated_at = {}\n", self.generated_at.packed()));
        out.push_str("\n[tournament_weights]\n");
        out.push_str(&format!("lattice = {}\n", self.tournament_weights.lattice));
        out.push_str(&format!("fingerprint = {}\n", self.tournament_weights.fingerprint));
        out.push_str(&format!("temporal = {}\n", self.tournament_weights.temporal));
        out.push_str(&format!("bitmap = {}\n", self.tournament_weights.bitmap));
        out.push_str(&format!("keystone = {}\n", self.tournament_weights.keystone));
        out.push_str(&format!("latent_factor = {}\n", self.tournament_weights.latent_factor));
        out.push_str("\n[ranking_weights]\n");
        out.push_str(&format!("lattice = {}\n", self.ranking_weights.lattice));
        out.push_str(&format!("fingerprint = {}\n", self.ranking_weights.fingerprint));
        out.push_str(&format!("temporal = {}\n", self.ranking_weights.temporal));
        out.push_str(&format!("bitmap = {}\n", self.ranking_weights.bitmap));
        out.push_str("\n[recall_trace_summary]\n");
        let mut keys: Vec<&String> = self.recall_trace_summary.bins.keys().collect();
        keys.sort();
        for k in keys {
            out.push_str(&format!("{} = {}\n", k, self.recall_trace_summary.bins[k]));
        }
        out.push_str("\n[preferred_pipelines]\n");
        for p in &self.preferred_pipelines {
            let chain = p.primitive_chain.join(" -> ");
            out.push_str(&format!("{} = {}\n", p.intent_tag, chain));
        }
        out.push_str("\n[lexicon]\n");
        let mut sorted = self.lexicon.clone();
        sorted.sort_by(|a, b| a.name.cmp(&b.name));
        for entry in sorted {
            out.push_str(&format!(
                "\"{}\" = {{ col = \"{}\", field = {}, value = {} }}\n",
                entry.name, entry.bitmap_column, entry.field_index, entry.value));
        }
        out
    }

    /// Compact binary serialization.
    pub fn to_binary(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.bundle_version.to_be_bytes());
        out.extend_from_slice(&self.estate_uuid);
        out.extend_from_slice(&self.generated_at.packed().to_be_bytes());
        // tournament weights
        out.extend_from_slice(&self.tournament_weights.lattice.to_bits().to_be_bytes());
        out.extend_from_slice(&self.tournament_weights.fingerprint.to_bits().to_be_bytes());
        out.extend_from_slice(&self.tournament_weights.temporal.to_bits().to_be_bytes());
        out.extend_from_slice(&self.tournament_weights.bitmap.to_bits().to_be_bytes());
        out.extend_from_slice(&self.tournament_weights.keystone.to_bits().to_be_bytes());
        out.extend_from_slice(&self.tournament_weights.latent_factor.to_bits().to_be_bytes());
        // ranking weights
        out.extend_from_slice(&self.ranking_weights.lattice.to_bits().to_be_bytes());
        out.extend_from_slice(&self.ranking_weights.fingerprint.to_bits().to_be_bytes());
        out.extend_from_slice(&self.ranking_weights.temporal.to_bits().to_be_bytes());
        out.extend_from_slice(&self.ranking_weights.bitmap.to_bits().to_be_bytes());
        // (recall trace, lexicon length-prefixed blocks follow;
        //  truncated in the reference for brevity)
        out
    }
}
