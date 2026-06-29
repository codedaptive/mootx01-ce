// api_payloads.rs — Rust twin of the Swift moot-mgr APIPayloads.swift.
//
// Codable payload structs for the moot-mgr loopback HTTP read-API. These shapes
// match the GUI SPEC §10 data-bindings table so the same web dashboard the
// Swift host serves binds directly to the Rust host's responses. The serde field
// names match the Swift `Codable` keys so the JSON byte-agrees across ports.
//
// CONTENT-SAFETY INVARIANT (concepts §1.6, GUI SPEC §10): every field here is
// metadata only — counts, enums, ISO-8601 timestamps, booleans, identifiers. No
// rung/memory content is ever projected onto a read payload.
//
// Timestamps are emitted as ISO-8601 UTC TEXT (matching the store's on-disk
// format) so the wire format is stable and human-readable, never epoch floats.

use serde::{Deserialize, Serialize};

use crate::admin_payloads::EstateAdminPayload;

/// Per-dropbox activity summary for the Connects tab and Overview observer panel.
/// Mirrors Swift `DropboxSummaryPayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DropboxSummaryPayload {
    pub name: String,
    #[serde(rename = "metricCount")]
    pub metric_count: i64,
    #[serde(rename = "eventCount")]
    pub event_count: i64,
    /// ISO-8601 UTC timestamp of the most-recent sample from this dropbox, or
    /// null when none.
    #[serde(rename = "lastSeenISO")]
    pub last_seen_iso: Option<String>,
}

/// Server / process / monitoring-state summary (GET /api/server). Mirrors Swift
/// `ServerPayload`. Server-metric fields are `None` until substrate probes land;
/// the dashboard renders n/a for them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ServerPayload {
    #[serde(rename = "monitoringEnabled")]
    pub monitoring_enabled: bool,
    #[serde(rename = "uptimeSeconds")]
    pub uptime_seconds: i64,
    #[serde(rename = "estateCount")]
    pub estate_count: i64,
    #[serde(rename = "totalMetrics")]
    pub total_metrics: i64,
    #[serde(rename = "totalEvents")]
    pub total_events: i64,
    #[serde(rename = "storeSizeBytes")]
    pub store_size_bytes: i64,
    #[serde(rename = "storePageCount")]
    pub store_page_count: Option<i32>,
    #[serde(rename = "storeFreelistPageCount")]
    pub store_freelist_page_count: Option<i32>,
    #[serde(rename = "storeWalFrameCount")]
    pub store_wal_frame_count: Option<i32>,
    #[serde(rename = "storeCacheHitRatio")]
    pub store_cache_hit_ratio: Option<f64>,
    #[serde(rename = "storeTransactionCommitCount")]
    pub store_transaction_commit_count: Option<i64>,
    #[serde(rename = "storeRowCount")]
    pub store_row_count: Option<i64>,
    #[serde(rename = "rssMb")]
    pub rss_mb: Option<f64>,
    #[serde(rename = "cpuUserMs")]
    pub cpu_user_ms: Option<f64>,
    #[serde(rename = "rpcCount")]
    pub rpc_count: Option<i64>,
    pub connections: Option<i64>,
    #[serde(rename = "protoVersion")]
    pub proto_version: Option<String>,
    #[serde(rename = "kernelBackend")]
    pub kernel_backend: Option<String>,
    #[serde(rename = "rpcRate")]
    pub rpc_rate: Option<f64>,
    #[serde(rename = "cpuPct")]
    pub cpu_pct: Option<f64>,
    #[serde(rename = "byDropbox")]
    pub by_dropbox: Vec<DropboxSummaryPayload>,
    pub capabilities: Vec<String>,
}

/// Queue backpressure snapshot for one estate (nested in EstatePayload). Mirrors
/// Swift `QueueStats`. All fields optional — absent when no queue samples exist.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QueueStats {
    pub depth: Option<f64>,
    #[serde(rename = "drainCount")]
    pub drain_count: Option<f64>,
    #[serde(rename = "idleNonempty")]
    pub idle_nonempty: Option<bool>,
    #[serde(rename = "latencyP50Ms")]
    pub latency_p50_ms: Option<f64>,
    #[serde(rename = "latencyP95Ms")]
    pub latency_p95_ms: Option<f64>,
    #[serde(rename = "headOfLineAgeS")]
    pub head_of_line_age_s: Option<f64>,
    #[serde(rename = "gateAdmitCount")]
    pub gate_admit_count: Option<f64>,
    #[serde(rename = "gateRejectCount")]
    pub gate_reject_count: Option<f64>,
}

/// One estate's rollup (GET /api/estates). Mirrors Swift `EstatePayload`.
/// Estate attribution is event-derived in the Phase-1 schema.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EstatePayload {
    pub id: String,
    #[serde(rename = "eventCount")]
    pub event_count: i64,
    #[serde(rename = "lastEventTs")]
    pub last_event_ts: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub queue: Option<QueueStats>,
}

/// Envelope for GET /api/estates: the event-derived rollups plus the admin
/// section. Mirrors Swift `EstatesPayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EstatesPayload {
    pub estates: Vec<EstatePayload>,
    /// Admin-hosted estates with their mount-state badges. `None` means the
    /// daemon admin proxy was unavailable (manager path); the HTTP read route
    /// always returns `Some` for the local admin plane even when `hosted` is empty.
    pub admin: Option<EstateAdminPayload>,
}

/// One recorded event row, projected for the Activity view / SSE stream (GET
/// /api/events). Metadata only — no rung content. Mirrors Swift `EventPayload`.
///
/// `drawerId` is always present on the wire (explicit null when absent) to match
/// the Swift custom-encode VIZ_V2 L1 contract; an empty estate row id projects
/// to null, never "".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventPayload {
    pub ts: String,
    pub kind: String,
    #[serde(rename = "nounType")]
    pub noun_type: i64,
    pub estate: String,
    pub dropbox: String,
    #[serde(rename = "drawerId")]
    pub drawer_id: Option<String>,
}

/// Envelope for the non-streaming GET /api/events response. Mirrors Swift
/// `EventsPayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventsPayload {
    pub events: Vec<EventPayload>,
}

/// Current monitoring configuration (GET /api/config). Mirrors Swift
/// `ConfigPayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConfigPayload {
    #[serde(rename = "monitoringEnabled")]
    pub monitoring_enabled: bool,
    #[serde(rename = "retentionSeconds")]
    pub retention_seconds: i64,
    /// ISO-8601 UTC timestamp the last retention pass rolled off data older than,
    /// or the epoch-zero sentinel if none has run.
    #[serde(rename = "retentionCutoff")]
    pub retention_cutoff: String,
}

/// One VizGraph analytic-signal summary row (nested in GraphPayload). Mirrors
/// Swift `GraphAnalyticPayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphAnalyticPayload {
    pub estate: String,
    pub signal: String,
    pub value: f64,
    pub ts: String,
    #[serde(rename = "sampleCount")]
    pub sample_count: i64,
}

/// One community legend entry on the wire (nested in GraphPayload). Mirrors
/// Swift `GraphCommunityPayload`. `label` is always present (explicit null).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphCommunityPayload {
    pub id: i64,
    pub label: Option<String>,
    pub size: i64,
}

/// One graph node (GET /api/graph, from the stored topology snapshot). Mirrors
/// Swift `GraphNodePayload`. Structural — passed through from the governor's
/// snapshot. Absent-key-tolerant on decode; explicit null on re-encode.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphNodePayload {
    pub id: String,
    #[serde(rename = "nounType")]
    pub noun_type: i64,
    #[serde(rename = "communityId")]
    pub community_id: i64,
    pub centrality: f64,
    pub anomaly: bool,
    #[serde(rename = "lastActiveTs", default)]
    pub last_active_ts: Option<String>,
    #[serde(rename = "createdTs", default)]
    pub created_ts: Option<String>,
    #[serde(rename = "tombstonedTs", default)]
    pub tombstoned_ts: Option<String>,
}

/// One graph edge (GET /api/graph). Mirrors Swift `GraphEdgePayload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphEdgePayload {
    pub source: String,
    pub target: String,
    #[serde(rename = "edgeType")]
    pub edge_type: String,
    pub weight: f64,
    #[serde(rename = "decayedWeight")]
    pub decayed_weight: f64,
    #[serde(rename = "createdTs", default)]
    pub created_ts: Option<String>,
    #[serde(rename = "tombstonedTs", default)]
    pub tombstoned_ts: Option<String>,
}

/// The Topology node-link snapshot (GET /api/graph). Mirrors Swift `GraphPayload`.
///
/// CONTENT-SAFETY INVARIANT: every field is metadata only — identifiers, integer
/// enums, float scores, ISO-8601 timestamps. No drawer text / KGFact predicates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphPayload {
    pub nodes: Vec<GraphNodePayload>,
    pub edges: Vec<GraphEdgePayload>,
    pub communities: Vec<GraphCommunityPayload>,
    pub analytics: Vec<GraphAnalyticPayload>,
    #[serde(rename = "structurePending")]
    pub structure_pending: bool,
    pub pending: Vec<String>,
    #[serde(rename = "generatedTs")]
    pub generated_ts: Option<String>,
    pub estate: String,
    #[serde(rename = "snapshotTs")]
    pub snapshot_ts: String,
}

/// The decodable envelope for a stored topology snapshot (what the governor
/// writes into `topology_snapshots`). Only the fields moot-mgr composes into
/// `GraphPayload` are decoded. Mirrors Swift `StoredGraphPayload`.
#[derive(Debug, Clone, Deserialize)]
pub struct StoredGraphPayload {
    #[serde(default)]
    pub nodes: Vec<GraphNodePayload>,
    #[serde(default)]
    pub edges: Vec<GraphEdgePayload>,
    #[serde(rename = "structurePending", default)]
    pub structure_pending: bool,
    #[serde(rename = "generatedTs", default)]
    pub generated_ts: Option<String>,
}

/// Result of a gated control verb (POST /api/control/* and UDS responses).
/// Mirrors Swift `ControlResult`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControlResult {
    pub ok: bool,
    pub detail: String,
}

impl ControlResult {
    pub fn new(ok: bool, detail: impl Into<String>) -> Self {
        ControlResult {
            ok,
            detail: detail.into(),
        }
    }
}

// MARK: - LexiconPayload (GET /api/lexicon)

/// The ARIA grammar as static JSON — one call, zero runtime cost. Mirrors Swift
/// `LexiconPayload`.
///
/// All fields are derived at startup from `aria-lexicon-lib`'s compile-time enum
/// definitions. The acceptance matrix is the full cross-product condensed to a
/// per-noun sorted array of the verb strings that apply.
///
/// LatticeLib metadata (FDC availability, data version, library version) is
/// included here because the dashboard's Configuration view renders it alongside
/// the lexicon.
///
/// CONTENT-SAFETY INVARIANT: this payload contains only grammar vocabulary and
/// library version strings — never any estate or content data.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LexiconPayload {
    /// All noun wire strings from `Noun::ALL` in declaration order.
    pub nouns: Vec<String>,
    /// All verb wire strings from `Verb::ALL` in declaration order.
    pub verbs: Vec<String>,
    /// All adjective wire strings from `Adjective::ALL` in declaration order.
    pub adjectives: Vec<String>,
    /// Per-noun acceptance map: noun wire string → sorted vec of accepted verb
    /// wire strings. Empty vec for nouns that accept nothing (e.g. "vector").
    /// `BTreeMap` gives sorted JSON key order — matches Swift's `.sortedKeys`.
    pub acceptance: std::collections::BTreeMap<String, Vec<String>>,
    /// Whether the FDC index is loaded. Sourced from `Fdc::is_available()`.
    #[serde(rename = "fdcAvailable")]
    pub fdc_available: bool,
    /// FDC data version string. Sourced from `Fdc::data_version()`.
    #[serde(rename = "fdcDataVersion")]
    pub fdc_data_version: String,
    /// LatticeLib library version string. Sourced from `Fdc::version()`.
    #[serde(rename = "latticeVersion")]
    pub lattice_version: String,
}

// MARK: - LatticeSnapshotPayload (GET /api/lattice)

/// One active lattice address and its drawer count. Mirrors Swift
/// `LatticeAddressPayload`.
///
/// CONTENT-SAFETY INVARIANT: only classification codes (decimal strings from the
/// FDC/MDCC taxonomy), bundled heading labels, and counts cross this surface.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LatticeAddressPayload {
    /// The UDC/MDCC classification code, e.g. "540", "006.6".
    pub code: String,
    /// The FDC frame heading label for this code, or null when not in the
    /// bundled frame or when LatticeLib is unavailable.
    pub label: Option<String>,
    /// Number of live (non-tombstoned) drawers anchored to this code.
    pub count: i64,
}

/// The lattice address snapshot returned by `GET /api/lattice`. Mirrors Swift
/// `LatticeSnapshotPayload`.
///
/// The Rust host proxies the live ARIA daemon's `/api/lattice` endpoint through
/// `daemon_client` and returns live addresses with `pending: false` on success.
/// The degraded state — empty address list with `pending: true` — is the fallback
/// returned on connection failure, HTTP error, or decode error. See
/// `manager.rs::lattice_payload` / `proxy_lattice_snapshot`.
///
/// CONTENT-SAFETY INVARIANT: classification metadata and counts only — never
/// estate content or rung text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LatticeSnapshotPayload {
    /// Active lattice addresses, sorted by count descending when live data is
    /// available. Empty in the honest degraded state (`pending: true`).
    pub addresses: Vec<LatticeAddressPayload>,
    /// True when ARIA_MCP was unreachable and the address list is empty.
    pub pending: bool,
}

// ───────────────────────── JSON encoding helper ─────────────────────────────

/// Encode a payload to compact JSON bytes with SORTED object keys (byte-stable,
/// testable, cache-friendly) — the Rust equivalent of the Swift
/// `JSONEncoder.outputFormatting = [.sortedKeys]` used by `APIJSON.encode`.
///
/// serde_json does not sort map keys by default, so this re-serializes through a
/// `serde_json::Value` and walks it emitting object keys in sorted order. Every
/// timestamp field is already an ISO-8601 String, so no date strategy is needed.
pub fn encode_sorted<T: Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    let v = serde_json::to_value(value)?;
    let mut out = Vec::new();
    write_sorted(&v, &mut out);
    Ok(out)
}

/// Recursively write a `serde_json::Value` as compact JSON with object keys in
/// sorted (lexicographic byte) order, matching Swift's `.sortedKeys`.
fn write_sorted(v: &serde_json::Value, out: &mut Vec<u8>) {
    match v {
        serde_json::Value::Object(map) => {
            out.push(b'{');
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            for (i, k) in keys.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                // Keys are JSON strings — serialize the key as a string scalar.
                let key_json = serde_json::Value::String((*k).clone());
                write_sorted(&key_json, out);
                out.push(b':');
                write_sorted(&map[*k], out);
            }
            out.push(b'}');
        }
        serde_json::Value::Array(arr) => {
            out.push(b'[');
            for (i, item) in arr.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_sorted(item, out);
            }
            out.push(b']');
        }
        // Scalars: serde_json's own compact encoding is canonical.
        scalar => {
            let s = serde_json::to_vec(scalar).expect("scalar re-encode cannot fail");
            out.extend_from_slice(&s);
        }
    }
}
