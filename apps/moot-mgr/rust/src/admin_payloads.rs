// admin_payloads.rs — Rust twin of the Swift moot-mgr AdminPayloads.swift.
//
// ========================== ADMIN = PRIVILEGED WRITES =======================
// The admin plane PROVISIONS and tears down estates — it creates real MOOTs
// through the GLK substrate and destroys their backing stores. These are the
// most privileged operations the resident host performs. EVERY admin verb is
// reached ONLY through the gated control surface (`HttpReadApi::apply_control`),
// which both the local gated IPC control channel (UDS on Unix, owner-ACL named
// pipe on Windows) and the token+Origin HTTP control path dispatch through.
// There is NO admin path on the unauthenticated
// read surface — the GET routes serve metadata only and never touch the engine.
//
// Everything here is metadata only (names, kinds, enums, counts, ISO-8601
// timestamps) — no rung/memory content ever crosses an admin response. Mirrors
// the Swift wire shapes field-for-field; the serde field names match the Swift
// `Codable` keys so the JSON byte-agrees across ports.

use serde::{Deserialize, Serialize};

/// The storage backend an admin client requests for a new estate. Mirrors Swift
/// `EstateBackendKind`. PostgreSQL is intentionally absent from this prototype
/// cut (it needs Keychain-held credentials — a separate P6 item).
///
/// The raw strings (`"InMemory"` / `"SQLite"`) match the Swift `EstateBackendKind`
/// raw values exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateBackendKind {
    /// Volatile in-memory backend — data is lost on process exit.
    InMemory,
    /// Durable SQLite file backend.
    Sqlite,
}

impl EstateBackendKind {
    /// Parse from the Swift raw-value string. Returns `None` for an unknown value.
    pub fn from_raw(s: &str) -> Option<Self> {
        match s {
            "InMemory" => Some(EstateBackendKind::InMemory),
            "SQLite" => Some(EstateBackendKind::Sqlite),
            _ => None,
        }
    }

    /// The Swift raw-value string.
    pub fn raw_value(self) -> &'static str {
        match self {
            EstateBackendKind::InMemory => "InMemory",
            EstateBackendKind::Sqlite => "SQLite",
        }
    }
}

/// The provisioning request an admin client sends to create a new estate.
/// Mirrors Swift `EstateAdminRequest`. Validated by the engine before any
/// storage is touched.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EstateAdminRequest {
    /// Human-readable estate name (non-empty). Written to the manifest.
    #[serde(rename = "estateName")]
    pub estate_name: String,
    /// Composition kind: "GLK" | "CorpusOnly" | "LocusOnly" (EstateKind raw value).
    pub kind: String,
    /// Storage backend: "InMemory" | "SQLite" (EstateBackendKind raw value).
    pub backend: String,
    /// Zoom-window lower bound (UDC lattice). Must be <= zoom_window_high.
    #[serde(rename = "zoomWindowLow")]
    pub zoom_window_low: i64,
    /// Zoom-window upper bound.
    #[serde(rename = "zoomWindowHigh")]
    pub zoom_window_high: i64,
    /// Framework profile name (unqualified; GLK adds the kind prefix on write).
    #[serde(rename = "frameworkProfile")]
    pub framework_profile: String,
    /// Sync mode: "None" | "CloudKit" | "Federation" (SyncMode raw value).
    #[serde(rename = "syncMode")]
    pub sync_mode: String,
    /// Owner identifier stamped on the new estate's manifest (non-empty).
    pub owner: String,
}

/// The body of a lifecycle verb (quiesce / drain / destroy): the estate UUID the
/// action targets. `destroy` additionally requires `confirm_name` to match the
/// estate's name (the double-confirm guard). Mirrors Swift `EstateLifecycleRequest`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EstateLifecycleRequest {
    /// Target estate UUID (string form of the estate handle's UUID).
    #[serde(rename = "estateUUID")]
    pub estate_uuid: String,
    /// For `destroy` only: the estate name the operator re-typed to confirm.
    /// Must equal the estate's stored name or the destroy is refused. Ignored by
    /// quiesce/drain. Optional so quiesce/drain bodies need not carry it.
    #[serde(rename = "confirmName", default, skip_serializing_if = "Option::is_none")]
    pub confirm_name: Option<String>,
}

/// The result of an admin verb. Carries `ok`/`detail` plus, on a successful
/// provision, the new estate's identity. Mirrors Swift `EstateAdminResult`.
///
/// Custom serialization is NOT used: `estate_uuid`/`mount_state` serialize as
/// explicit JSON null when `None` (matching the Swift `Codable` default for an
/// optional, which emits null), so the `ControlResponse` envelope can recover
/// `ok` from the encoded bytes uniformly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EstateAdminResult {
    /// Whether the verb succeeded.
    pub ok: bool,
    /// Human-readable detail ("provisioned GLK estate …", "quiesced", an error).
    pub detail: String,
    /// The affected estate's UUID, when known. `None` on a request that failed
    /// before an estate could be identified (e.g. a malformed body).
    #[serde(rename = "estateUUID")]
    pub estate_uuid: Option<String>,
    /// The affected estate's current mount state after the verb, when known.
    #[serde(rename = "mountState")]
    pub mount_state: Option<String>,
}

impl EstateAdminResult {
    /// A success/failure result with no estate identity (the common refusal shape).
    pub fn of(ok: bool, detail: impl Into<String>) -> Self {
        EstateAdminResult {
            ok,
            detail: detail.into(),
            estate_uuid: None,
            mount_state: None,
        }
    }
}

/// One admin-hosted estate as reflected back into the read plane. Mirrors Swift
/// `EstateAdminEntry`. Metadata only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EstateAdminEntry {
    /// Estate UUID (string).
    #[serde(rename = "estateUUID")]
    pub estate_uuid: String,
    /// Display name from the manifest.
    #[serde(rename = "estateName")]
    pub estate_name: String,
    /// Composition kind raw value ("GLK" | "CorpusOnly" | "LocusOnly").
    pub kind: String,
    /// Backend raw value ("InMemory" | "SQLite"). InMemory is flagged volatile
    /// by the renderer.
    pub backend: String,
    /// Current mount-state raw value ("mounted" | "quiesced" | "draining").
    #[serde(rename = "mountState")]
    pub mount_state: String,
}

/// The admin section merged into the `GET /api/estates` payload: the estates the
/// resident host itself provisions and mounts. Mirrors Swift `EstateAdminPayload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EstateAdminPayload {
    /// Admin-hosted estates, sorted by UUID for byte-stable output.
    pub hosted: Vec<EstateAdminEntry>,
}
