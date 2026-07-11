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

use serde::{Deserialize, Serialize, Serializer, ser::SerializeSeq};

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
/// Swift `GraphCommunityPayload`. `code` and `label` are always present
/// (explicit null). `code` is the community's dominant UDC/FDC classification
/// code — the dashboard derives the community color from its digits
/// (hundreds → hue, tens → shade, ones → brightness). Populated by the
/// stored-snapshot enrichment (`Manager::enrich_communities`); the count-only
/// local fallback emits explicit nulls.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphCommunityPayload {
    pub id: i64,
    pub code: Option<String>,
    pub label: Option<String>,
    pub size: i64,
    #[serde(rename = "stableKey", skip_serializing_if = "Option::is_none", default)]
    pub stable_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub z: Option<f64>,
    #[serde(rename = "foldCount", skip_serializing_if = "Option::is_none", default)]
    pub fold_count: Option<i64>,
    #[serde(rename = "representativeIds", skip_serializing_if = "Option::is_none", default)]
    pub representative_ids: Option<Vec<String>>,
    #[serde(rename = "classificationPurity", skip_serializing_if = "Option::is_none", default)]
    pub classification_purity: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphFoldPayload {
    #[serde(rename = "stableKey")]
    pub stable_key: String,
    #[serde(rename = "communityKey")]
    pub community_key: String,
    pub code: Option<String>,
    pub label: Option<String>,
    pub size: i64,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    #[serde(rename = "representativeIds")]
    pub representative_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphBridgePayload {
    pub level: String,
    #[serde(rename = "sourceKey")]
    pub source_key: String,
    #[serde(rename = "targetKey")]
    pub target_key: String,
    #[serde(rename = "edgeType")]
    pub edge_type: String,
    pub weight: f64,
    #[serde(rename = "edgeCount")]
    pub edge_count: i64,
}

/// One graph node (GET /api/graph, from the stored topology snapshot). Mirrors
/// Stored node shape decoded from governor-written topology_snapshots.
/// Mirrors Swift `GraphNodePayload`. Absent-key-tolerant; decode-only.
///
/// nounType and lastActiveTs removed from wire format (FIX 2 — payload trim):
/// nounType was redundant (all drawers are type 0); lastActiveTs is not
/// surfaced by the dashboard renderer.  The `#[serde(default)]` on absent
/// fields means existing snapshots with these keys still decode without error.
///
/// `udc_code` (V2-P1b) is the node's FDC/UDC classification code, decoded
/// tolerantly — `#[serde(default)]` means stored snapshots written before
/// this field existed still decode (absent key → `None`). It is dictionary-
/// encoded onto the compact `/api/graph` wire (`codes`/`code_index` on
/// `GraphPayload`, built in `MootManager::graph_payload`), never re-emitted
/// per-node.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct GraphNodePayload {
    pub id: String,
    #[serde(rename = "communityId", default)]
    pub community_id: i64,
    #[serde(default)]
    pub centrality: f64,
    #[serde(default)]
    pub anomaly: bool,
    #[serde(rename = "createdTs", default)]
    pub created_ts: Option<String>,
    #[serde(rename = "tombstonedTs", default)]
    pub tombstoned_ts: Option<String>,
    #[serde(rename = "udcCode", default)]
    pub udc_code: Option<String>,
    #[serde(rename = "communityKey", default)]
    pub community_key: Option<String>,
    #[serde(rename = "foldKey", default)]
    pub fold_key: Option<String>,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub z: Option<f64>,
    #[serde(default)]
    pub representative: bool,
}

/// Stored edge shape decoded from governor-written topology_snapshots.
/// Mirrors Swift `GraphEdgePayload`. Absent-key-tolerant; decode-only.
///
/// `created_ts` is retained from governor snapshots so the compact public wire
/// can restore truthful explicit-edge replay. Derived bonds carry `None`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct GraphEdgePayload {
    pub source: String,
    pub target: String,
    #[serde(rename = "edgeType", default)]
    pub edge_type: String,
    #[serde(default = "default_weight")]
    pub weight: f64,
    #[serde(rename = "createdTs", default)]
    pub created_ts: Option<String>,
    #[serde(rename = "tombstonedTs", default)]
    pub tombstoned_ts: Option<String>,
}

fn default_weight() -> f64 { 0.5 }

/// Compact wire-format edge for the `/api/graph` response (FIX 2b).
///
/// Serializes with a four-field structural prefix `[si, ti, w, et]`.
/// Explicit edges append factual second offsets from GraphPayload's shared
/// `edge_time_origin`; derived present-day inference edges remain four fields.
///
/// Edge-type ordinal mapping (matches app.js `edgeTypeNames` constant):
/// - 0 = "tunnel"      (default)
/// - 1 = "kgFact"
/// - 2 = "association"
/// - 3 = "nmf_bond"
#[derive(Debug, Clone, PartialEq)]
pub struct CompactEdge {
    /// Index of the source node in the parallel `ids` array.
    pub si: usize,
    /// Index of the target node in the parallel `ids` array.
    pub ti: usize,
    /// Raw edge weight in [0, 1].
    pub w: f64,
    /// Edge-type ordinal: 0=tunnel, 1=kgFact, 2=association, 3=nmf_bond.
    pub et: u8,
    /// Factual explicit-edge creation offset from GraphPayload.edge_time_origin.
    pub born: Option<i64>,
    /// Factual tombstone offset from GraphPayload.edge_time_origin.
    pub dead: Option<i64>,
}

impl CompactEdge {
    /// Map an ARIA edge-type string to its compact ordinal.
    pub fn edge_type_ordinal(edge_type: &str) -> u8 {
        match edge_type {
            "kgFact"      => 1,
            "association" => 2,
            "nmf_bond"    => 3,
            _             => 0,  // "tunnel" and any unrecognised type
        }
    }
}

impl Serialize for CompactEdge {
    /// Serialize a variable-length flat array. This keeps derived edges at the
    /// original four fields and charges timestamp bytes only to explicit edges.
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let len = if self.dead.is_some() { 6 } else if self.born.is_some() { 5 } else { 4 };
        let mut seq = s.serialize_seq(Some(len))?;
        seq.serialize_element(&self.si)?;
        seq.serialize_element(&self.ti)?;
        seq.serialize_element(&self.w)?;
        seq.serialize_element(&self.et)?;
        if self.born.is_some() || self.dead.is_some() {
            seq.serialize_element(&self.born)?;
        }
        if let Some(dead) = self.dead {
            seq.serialize_element(&dead)?;
        }
        seq.end()
    }
}

/// Parse the governor's canonical UTC ISO-8601 timestamps into epoch seconds.
/// Fractional seconds are intentionally ignored: compact replay uses second
/// resolution. Non-canonical/non-UTC values degrade to `None`.
pub(crate) fn topology_epoch_seconds(value: Option<&str>) -> Option<i64> {
    let b = value?.as_bytes();
    if b.len() < 20 || *b.last()? != b'Z'
        || b[4] != b'-' || b[7] != b'-' || b[10] != b'T'
        || b[13] != b':' || b[16] != b':' {
        return None;
    }
    fn digits(b: &[u8], start: usize, count: usize) -> Option<i64> {
        let mut n = 0_i64;
        for &v in b.get(start..start + count)? {
            if !v.is_ascii_digit() { return None; }
            n = n * 10 + i64::from(v - b'0');
        }
        Some(n)
    }
    let mut year = digits(b, 0, 4)?;
    let month = digits(b, 5, 2)?;
    let day = digits(b, 8, 2)?;
    let hour = digits(b, 11, 2)?;
    let minute = digits(b, 14, 2)?;
    let second = digits(b, 17, 2)?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day)
        || hour >= 24 || minute >= 60 || second >= 61 {
        return None;
    }
    if month <= 2 { year -= 1; }
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * adjusted_month + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

#[cfg(test)]
mod compact_time_tests {
    use super::{topology_epoch_seconds, CompactEdge};

    #[test]
    fn canonical_iso_parses_to_epoch_seconds() {
        assert_eq!(topology_epoch_seconds(Some("1970-01-01T00:00:00Z")), Some(0));
        assert_eq!(topology_epoch_seconds(Some("2026-06-09T20:13:05Z")), Some(1_781_035_985));
        assert_eq!(topology_epoch_seconds(Some("2026-06-09T20:13:05.999Z")), Some(1_781_035_985));
        assert_eq!(topology_epoch_seconds(Some("2026-06-09T20:13:05+00:00")), None);
    }

    #[test]
    fn compact_edge_temporal_suffix_is_variable_length() {
        let derived = serde_json::to_string(&CompactEdge {
            si: 0, ti: 1, w: 0.3, et: 1, born: None, dead: None,
        }).unwrap();
        let live = serde_json::to_string(&CompactEdge {
            si: 0, ti: 1, w: 1.0, et: 0, born: Some(100), dead: None,
        }).unwrap();
        let dead = serde_json::to_string(&CompactEdge {
            si: 0, ti: 1, w: 1.0, et: 0, born: Some(100), dead: Some(200),
        }).unwrap();
        assert_eq!(derived, "[0,1,0.3,1]");
        assert_eq!(live, "[0,1,1.0,0,100]");
        assert_eq!(dead, "[0,1,1.0,0,100,200]");
    }
}

/// The Topology node-link snapshot (GET /api/graph). Mirrors Swift `GraphPayload`.
///
/// ## Wire format (FIX 2b compact layout)
///
/// Nodes are encoded as parallel arrays to eliminate per-node key overhead:
///
///   `ids`          — `[String]` UUID per node
///   `communityId`  — `[i64]` Louvain community id per node
///   `centrality`   — `[f64]` eigenvalue-centrality in [0, 1] per node
///   `anomaly`      — `[bool]` anomaly flag per node
///   `createdTs`    — `[String?]` ISO-8601 ingest timestamp or null per node
///   `tombstoned`   — `{indexStr: ts}` SPARSE map (tombstoned nodes only)
///
/// Per-node classification codes are dictionary-encoded (V2-P1b), same
/// rationale as the compact edges below — ~10^2 distinct codes vs up to 50k
/// nodes:
///
///   `codes`        — `[String]` deduped code dictionary, first-seen order
///   `codeIndex`    — `[i64]` index into `codes` per node, parallel to `ids`;
///                    `-1` means the node has no code
///
/// Edges are compact arrays-of-arrays:
///   `edges` — `[[si, ti, w, et, born?, dead?], ...]`
///
/// Old per-object `"nodes"` key is absent from the wire. See `StoredGraphPayload`
/// for the decode-only shape used to read governor-written snapshots.
///
/// CONTENT-SAFETY INVARIANT: all fields are metadata only — identifiers, integer
/// enums, float scores, ISO-8601 timestamps. No drawer text / KGFact predicates.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GraphPayload {
    /// Parallel node arrays.
    pub ids: Vec<String>,
    #[serde(rename = "communityId")]
    pub community_id: Vec<i64>,
    pub centrality: Vec<f64>,
    pub anomaly: Vec<bool>,
    /// createdTs parallel array — null entries serialize as JSON null.
    #[serde(rename = "createdTs",
            serialize_with = "serialize_option_vec")]
    pub created_ts: Vec<Option<String>>,
    /// Sparse tombstone map: string(nodeIndex) → ISO-8601 ts.
    pub tombstoned: std::collections::HashMap<String, String>,
    /// Deduped classification-code dictionary, first-seen order over the
    /// node array (V2-P1b). Sized to the distinct-code count (~10^2), not
    /// the node count (up to 50k) — keeps the payload inside the 5 MB ceiling.
    pub codes: Vec<String>,
    /// Index into `codes` per node, parallel to `ids`. `-1` means the node
    /// carries no code (absent or empty `udcCode`).
    #[serde(rename = "codeIndex")]
    pub code_index: Vec<i64>,
    #[serde(rename = "positionQ16")]
    pub position_q16: String,
    pub representatives: Vec<usize>,
    /// Compact edges: each element serializes as [si, ti, w, et].
    pub edges: Vec<CompactEdge>,
    /// Shared epoch-second origin for factual CompactEdge time suffixes.
    #[serde(rename = "edgeTimeOrigin")]
    pub edge_time_origin: Option<i64>,
    pub communities: Vec<GraphCommunityPayload>,
    pub folds: Vec<GraphFoldPayload>,
    pub bridges: Vec<GraphBridgePayload>,
    #[serde(rename = "topologyVersion")]
    pub topology_version: i64,
    #[serde(rename = "coordinateFrameVersion")]
    pub coordinate_frame_version: i64,
    #[serde(rename = "viewLevel")]
    pub view_level: String,
    #[serde(rename = "focusKey")]
    pub focus_key: Option<String>,
    #[serde(rename = "activityIds")]
    pub activity_ids: Vec<String>,
    #[serde(rename = "activityKeys")]
    pub activity_keys: Vec<String>,
    #[serde(rename = "totalNodeCount")]
    pub total_node_count: usize,
    #[serde(rename = "totalEdgeCount")]
    pub total_edge_count: usize,
    #[serde(rename = "lodTruncated")]
    pub lod_truncated: bool,
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

/// Serialize `Vec<Option<String>>` so each `None` becomes a JSON null.
fn serialize_option_vec<S>(v: &[Option<String>], s: S) -> Result<S::Ok, S::Error>
where S: Serializer {
    let mut seq = s.serialize_seq(Some(v.len()))?;
    for item in v {
        seq.serialize_element(item)?;
    }
    seq.end()
}

/// One governor-written community descriptor inside a stored topology
/// snapshot: `{id, size, dominantUdcCode}`. Mirrors Swift
/// `ARIACommunityDescriptor`. `dominantUdcCode` decodes tolerantly (absent on
/// older daemons → None).
#[derive(Debug, Clone, Deserialize, Default)]
pub struct AriaCommunityDescriptor {
    pub id: i64,
    #[serde(default)]
    pub size: i64,
    #[serde(rename = "dominantUdcCode", default)]
    pub dominant_udc_code: Option<String>,
    #[serde(rename = "stableKey", default)]
    pub stable_key: Option<String>,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub z: Option<f64>,
    #[serde(rename = "foldCount", default)]
    pub fold_count: Option<i64>,
    #[serde(rename = "representativeIds", default)]
    pub representative_ids: Option<Vec<String>>,
    #[serde(rename = "classificationPurity", default)]
    pub classification_purity: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AriaFoldDescriptor {
    #[serde(rename = "stableKey")]
    pub stable_key: String,
    #[serde(rename = "communityKey")]
    pub community_key: String,
    pub size: i64,
    #[serde(rename = "dominantUdcCode", default)]
    pub dominant_udc_code: Option<String>,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    #[serde(rename = "representativeIds", default)]
    pub representative_ids: Vec<String>,
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
    /// Governor community descriptors (VIZ_V2 L3). None when the snapshot
    /// predates the communities field — the count-only local rollup then
    /// stays in effect.
    #[serde(default)]
    pub communities: Option<Vec<AriaCommunityDescriptor>>,
    #[serde(rename = "topologyVersion", default)]
    pub topology_version: Option<i64>,
    #[serde(rename = "coordinateFrameVersion", default)]
    pub coordinate_frame_version: Option<i64>,
    #[serde(default)]
    pub folds: Vec<AriaFoldDescriptor>,
    #[serde(default)]
    pub bridges: Vec<GraphBridgePayload>,
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
