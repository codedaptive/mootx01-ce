//! transfer_manifest.rs — the transfer manifest, ground truth for verification.
//!
//! Ports `Manifest.swift` (distinct from `CapabilityManifest.swift`, which is
//! ported in [`crate::manifest`]). The manifest lists exactly what was
//! transferred from source to target. The benchmarker verifies each manifest
//! entry against the TARGET — the manifest, not the source's live state, is the
//! authority for "did this item make it and rank correctly."
//!
//! Codable parity: the Swift `Manifest` decodes `captureLatencies` with
//! `decodeIfPresent ?? []`, so a manifest written without that key (or by an
//! older build) still decodes with an empty series. The Rust decode reproduces
//! that — an absent `captureLatencies` defaults to empty.

use serde::{Deserialize, Serialize};

/// Outcome of attempting to transfer one entry to the target. An enum, not a
/// bool — a permanently failed entry is recorded rather than silently dropped.
/// Mirrors Swift `TransferOutcome`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TransferOutcome {
    Transferred,
    Failed,
}

/// One transferred entry. `transferred_at` is an ISO8601 TEXT timestamp.
/// Mirrors Swift `ManifestEntry`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestEntry {
    pub id: String,
    pub content: String,
    #[serde(rename = "transferredAt")]
    pub transferred_at: String,
    pub outcome: TransferOutcome,
}

/// A single verification probe derived from a manifest entry: query the
/// target's `query` tool with the entry's content and expect the entry's id at
/// rank 1. Mirrors Swift `VerificationQuery`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerificationQuery {
    pub query_tool: String,
    pub query_text: String,
    pub expected_rank1_id: String,
}

/// The ground-truth record of a transfer run. Mirrors Swift `Manifest`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Manifest {
    entries: Vec<ManifestEntry>,
    /// Per-write capture latencies (seconds). Absent in older manifests →
    /// defaults to empty on decode (matches Swift `decodeIfPresent ?? []`).
    #[serde(rename = "captureLatencies", default)]
    capture_latencies: Vec<f64>,
}

impl Manifest {
    /// Creates an empty manifest.
    pub fn new() -> Manifest {
        Manifest::default()
    }

    /// The recorded entries, in transfer order.
    pub fn entries(&self) -> &[ManifestEntry] {
        &self.entries
    }

    /// The recorded per-write capture latencies (seconds).
    pub fn capture_latencies(&self) -> &[f64] {
        &self.capture_latencies
    }

    /// Appends a recorded entry. Mirrors Swift `Manifest.record`.
    pub fn record(&mut self, entry: ManifestEntry) {
        self.entries.push(entry);
    }

    /// Records one capture latency (seconds). Mirrors Swift
    /// `Manifest.recordCaptureLatency`.
    pub fn record_capture_latency(&mut self, seconds: f64) {
        self.capture_latencies.push(seconds);
    }

    /// True when an entry with this id was recorded (any outcome). Mirrors
    /// Swift `Manifest.contains(id:)`.
    pub fn contains(&self, id: &str) -> bool {
        self.entries.iter().any(|e| e.id == id)
    }

    /// One verification query per successfully transferred entry. Failed
    /// entries are excluded. Mirrors Swift `Manifest.verificationQueries`.
    pub fn verification_queries(&self, query_tool: &str) -> Vec<VerificationQuery> {
        self.entries
            .iter()
            .filter(|e| e.outcome == TransferOutcome::Transferred)
            .map(|e| VerificationQuery {
                query_tool: query_tool.to_string(),
                query_text: e.content.clone(),
                expected_rank1_id: e.id.clone(),
            })
            .collect()
    }

    /// Decodes a manifest from JSON bytes. Mirrors loading a persisted manifest.
    pub fn from_slice(data: &[u8]) -> Result<Manifest, serde_json::Error> {
        serde_json::from_slice(data)
    }

    /// Serializes the manifest to JSON bytes.
    pub fn to_vec(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, content: &str, outcome: TransferOutcome) -> ManifestEntry {
        ManifestEntry {
            id: id.to_string(),
            content: content.to_string(),
            transferred_at: "2026-06-10T00:00:00Z".to_string(),
            outcome,
        }
    }

    #[test]
    fn records_and_contains() {
        let mut m = Manifest::new();
        m.record(entry("a", "alpha", TransferOutcome::Transferred));
        m.record_capture_latency(0.012);
        assert!(m.contains("a"));
        assert!(!m.contains("z"));
        assert_eq!(m.capture_latencies(), &[0.012]);
    }

    #[test]
    fn verification_queries_exclude_failed() {
        let mut m = Manifest::new();
        m.record(entry("a", "alpha", TransferOutcome::Transferred));
        m.record(entry("b", "beta", TransferOutcome::Failed));
        m.record(entry("c", "gamma", TransferOutcome::Transferred));
        let qs = m.verification_queries("moot_memory_search");
        assert_eq!(qs.len(), 2);
        assert_eq!(qs[0].expected_rank1_id, "a");
        assert_eq!(qs[0].query_text, "alpha");
        assert_eq!(qs[0].query_tool, "moot_memory_search");
        assert_eq!(qs[1].expected_rank1_id, "c");
    }

    #[test]
    fn outcome_serializes_lowercase() {
        let e = entry("a", "x", TransferOutcome::Transferred);
        let json = serde_json::to_string(&e).unwrap();
        assert!(json.contains(r#""outcome":"transferred""#));
        assert!(json.contains(r#""transferredAt":"#));
    }

    #[test]
    fn decodes_without_capture_latencies() {
        // An older manifest with no captureLatencies key still decodes.
        let json = r#"{
            "entries": [
                { "id": "a", "content": "alpha", "transferredAt": "2026-06-10T00:00:00Z", "outcome": "transferred" }
            ]
        }"#;
        let m = Manifest::from_slice(json.as_bytes()).unwrap();
        assert_eq!(m.entries().len(), 1);
        assert!(m.capture_latencies().is_empty());
    }

    #[test]
    fn round_trips_through_json() {
        let mut m = Manifest::new();
        m.record(entry("a", "alpha", TransferOutcome::Transferred));
        m.record_capture_latency(0.5);
        let bytes = m.to_vec().unwrap();
        let back = Manifest::from_slice(&bytes).unwrap();
        assert_eq!(m, back);
    }
}
