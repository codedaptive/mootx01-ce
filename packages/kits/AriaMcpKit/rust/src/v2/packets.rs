//! Typed ARIA v2 work-packet operations.
//!
//! This module deliberately owns packet decoding and the narrow direct
//! LocusKit execution path.  The selected-surface registry wires these
//! functions later; this file neither invokes nor adapts a legacy runner.

use std::collections::{BTreeMap, HashSet};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer::Drawer,
    drawer_operational::{CaptureChannel, ContentKind},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, TunnelCaptureFrame},
    tunnel_operational::{TunnelKind, TunnelOriginClass},
};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use uuid::Uuid;

use crate::sensitivity_grant_ledger::SensitivityGrantLedger;

pub const PACKET_SCHEMA_VERSION: i64 = 1;
pub const PACKET_ROOM: &str = "work-packets";
pub const PACKET_UDC: &str = "004";
pub const PACKET_ADDED_BY: &str = "WorkPacketKit";
pub const PACKET_EMBEDDING_MODEL: &str = "none";
pub const DEFAULT_WING: &str = "Agentic Memory";

/// A packet payload retains fields newer than this reader so a read/write
/// cycle cannot erase an extension owned by a later schema version.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkPacket {
    pub schema_version: i64,
    pub id: String,
    pub objective: String,
    #[serde(default)]
    pub sources: Vec<PacketSource>,
    #[serde(default)]
    pub claims: Vec<PacketClaim>,
    #[serde(default)]
    pub uncertainties: Vec<String>,
    #[serde(default)]
    pub next_steps: Vec<String>,
    pub provenance: PacketProvenance,
    #[serde(default)]
    pub lineage_links: Vec<LineageLink>,
    #[serde(flatten, default)]
    pub additional_fields: BTreeMap<String, Value>,
}

impl WorkPacket {
    pub fn decode_storage(content: &str) -> Result<Self, PacketToolError> {
        let mut packet: Self = serde_json::from_str(content)
            .map_err(|error| PacketToolError::invalid("packet", format!("invalid packet JSON: {error}")))?;
        packet.validate()?;
        packet.id = canonical_uuid(&packet.id, "packet.id")?;
        for source in &mut packet.sources {
            source.id = canonical_uuid(&source.id, "packet.sources[].id")?;
        }
        for claim in &mut packet.claims {
            claim.id = canonical_uuid(&claim.id, "packet.claims[].id")?;
        }
        for link in &mut packet.lineage_links {
            link.target_packet_id = canonical_uuid(&link.target_packet_id, "packet.lineageLinks[].targetPacketID")?;
        }
        Ok(packet)
    }

    pub fn encode_storage(&self) -> Result<String, PacketToolError> {
        self.validate()?;
        serde_json::to_string(self)
            .map_err(|error| PacketToolError::operational(format!("packet JSON encoding failed: {error}")))
    }

    pub fn is_future_schema(&self) -> bool {
        self.schema_version > PACKET_SCHEMA_VERSION
    }

    fn validate(&self) -> Result<(), PacketToolError> {
        if self.schema_version < 1 {
            return Err(PacketToolError::invalid("packet.schemaVersion", "schemaVersion must be at least 1"));
        }
        canonical_uuid(&self.id, "packet.id")?;
        require_nonempty(&self.objective, "packet.objective")?;
        require_nonempty(&self.provenance.model, "packet.provenance.model")?;
        require_nonempty(&self.provenance.agent, "packet.provenance.agent")?;
        for source in &self.sources {
            source.validate()?;
        }
        for claim in &self.claims {
            claim.validate()?;
        }
        for link in &self.lineage_links {
            link.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PacketSource {
    pub id: String,
    pub description: String,
    pub uri: Option<String>,
    pub kind: String,
}

impl PacketSource {
    fn validate(&self) -> Result<(), PacketToolError> {
        canonical_uuid(&self.id, "packet.sources[].id")?;
        require_nonempty(&self.description, "packet.sources[].description")?;
        require_nonempty(&self.kind, "packet.sources[].kind")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PacketClaim {
    pub id: String,
    pub statement: String,
    pub confidence: f64,
    #[serde(rename = "supportingSourceIDs", default)]
    pub supporting_source_ids: Vec<String>,
}

impl PacketClaim {
    fn validate(&self) -> Result<(), PacketToolError> {
        canonical_uuid(&self.id, "packet.claims[].id")?;
        require_nonempty(&self.statement, "packet.claims[].statement")?;
        validate_confidence(self.confidence, "packet.claims[].confidence")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PacketProvenance {
    pub model: String,
    pub agent: String,
    pub created_at: Iso8601Timestamp,
    pub updated_at: Iso8601Timestamp,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineageLink {
    pub kind: LineageKind,
    #[serde(rename = "targetPacketID")]
    pub target_packet_id: String,
}

impl LineageLink {
    fn validate(&self) -> Result<(), PacketToolError> {
        canonical_uuid(&self.target_packet_id, "packet.lineageLinks[].targetPacketID")?;
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LineageKind {
    #[serde(rename = "derivesFrom")]
    DerivesFrom,
    #[serde(rename = "respondsTo")]
    RespondsTo,
}

impl LineageKind {
    fn tunnel_kind(self) -> TunnelKind {
        match self {
            Self::DerivesFrom => TunnelKind::DerivesFrom,
            Self::RespondsTo => TunnelKind::RespondsTo,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::DerivesFrom => "derivesFrom",
            Self::RespondsTo => "respondsTo",
        }
    }
}

/// A validated RFC 3339 / ISO-8601 instant.  Storage keeps its canonical UTC
/// spelling, matching the Swift packet encoder's ISO-8601 output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Iso8601Timestamp(String);

impl Iso8601Timestamp {
    pub fn from_epoch_millis(epoch_millis: i64) -> Self {
        Self(format_epoch_millis(epoch_millis))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Serialize for Iso8601Timestamp {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for Iso8601Timestamp {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        parse_iso8601_millis(&value)
            .map(|millis| Self(format_epoch_millis(millis)))
            .map_err(serde::de::Error::custom)
    }
}

/// Strictly decoded request for `moot_file_packet`.
#[derive(Debug, Clone, PartialEq)]
pub struct FilePacketRequest {
    pub packet: WorkPacket,
    pub wing: String,
    pub sensitivity: AdjectiveSensitivity,
}

impl FilePacketRequest {
    pub fn decode(
        args: &BTreeMap<String, Value>,
        now_millis: i64,
        grant_ceiling: Option<AdjectiveSensitivity>,
    ) -> Result<Self, PacketToolError> {
        reject_unknown(args, &[
            "estate_id", "objective", "sources", "claims", "uncertainties", "next_steps",
            "model", "agent", "sensitivity", "lineage_links", "wing",
        ])?;
        let objective = required_string(args, "objective")?;
        let model = required_string(args, "model")?;
        let agent = required_string(args, "agent")?;
        let wing = optional_string(args, "wing")?.unwrap_or_else(|| DEFAULT_WING.to_string());
        require_nonempty(&wing, "wing")?;
        let requested = optional_sensitivity(args)?;
        let sensitivity = match (requested, grant_ceiling) {
            (None, Some(ceiling)) => ceiling,
            (Some(value), Some(ceiling)) if sensitivity_rank(value) < sensitivity_rank(ceiling) => {
                return Err(PacketToolError::operational(format!(
                    "sensitivity {} is below the live grant ceiling {}",
                    sensitivity_name(value), sensitivity_name(ceiling)
                )));
            }
            (Some(value), _) => value,
            (None, None) => AdjectiveSensitivity::Normal,
        };
        let packet = WorkPacket {
            schema_version: PACKET_SCHEMA_VERSION,
            id: Uuid::new_v4().to_string(),
            objective,
            sources: decode_sources(args.get("sources"))?,
            claims: decode_claims(args.get("claims"))?,
            uncertainties: decode_string_array(args.get("uncertainties"), "uncertainties")?,
            next_steps: decode_string_array(args.get("next_steps"), "next_steps")?,
            provenance: PacketProvenance {
                model,
                agent,
                created_at: Iso8601Timestamp::from_epoch_millis(now_millis),
                updated_at: Iso8601Timestamp::from_epoch_millis(now_millis),
            },
            lineage_links: decode_lineage_links(args.get("lineage_links"))?,
            additional_fields: BTreeMap::new(),
        };
        packet.validate()?;
        Ok(Self { packet, wing, sensitivity })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GetPacketRequest {
    pub drawer_id: String,
    pub wing: Option<String>,
}

impl GetPacketRequest {
    pub fn decode(args: &BTreeMap<String, Value>) -> Result<Self, PacketToolError> {
        reject_unknown(args, &["estate_id", "drawer_id", "wing"])?;
        let drawer_id = canonical_uuid(&required_string(args, "drawer_id")?, "drawer_id")?;
        let wing = optional_string(args, "wing")?;
        if let Some(value) = &wing { require_nonempty(value, "wing")?; }
        Ok(Self { drawer_id, wing })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListPacketsRequest {
    pub wing: String,
    pub limit: usize,
}

impl ListPacketsRequest {
    pub fn decode(args: &BTreeMap<String, Value>) -> Result<Self, PacketToolError> {
        reject_unknown(args, &["estate_id", "wing", "limit"])?;
        let wing = optional_string(args, "wing")?.unwrap_or_else(|| DEFAULT_WING.to_string());
        require_nonempty(&wing, "wing")?;
        let limit = match args.get("limit") {
            None => 20,
            Some(Value::Number(value)) => value.as_u64()
                .filter(|value| (1..=100).contains(value))
                .map(|value| value as usize)
                .ok_or_else(|| PacketToolError::invalid("limit", "limit must be an integer from 1 through 100"))?,
            Some(_) => return Err(PacketToolError::invalid("limit", "limit must be an integer from 1 through 100")),
        };
        Ok(Self { wing, limit })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LineageRequest {
    pub drawer_id: String,
    pub wing: Option<String>,
    pub max_depth: usize,
}

impl LineageRequest {
    pub fn decode(args: &BTreeMap<String, Value>) -> Result<Self, PacketToolError> {
        reject_unknown(args, &["estate_id", "drawer_id", "wing", "max_depth"])?;
        let drawer_id = canonical_uuid(&required_string(args, "drawer_id")?, "drawer_id")?;
        let wing = optional_string(args, "wing")?;
        if let Some(value) = &wing { require_nonempty(value, "wing")?; }
        let max_depth = match args.get("max_depth") {
            None => 10,
            Some(Value::Number(value)) => value.as_u64()
                .filter(|value| (1..=50).contains(value))
                .map(|value| value as usize)
                .ok_or_else(|| PacketToolError::invalid("max_depth", "max_depth must be an integer from 1 through 50"))?,
            Some(_) => return Err(PacketToolError::invalid("max_depth", "max_depth must be an integer from 1 through 50")),
        };
        Ok(Self { drawer_id, wing, max_depth })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FilePacketResult {
    pub drawer_id: String,
    pub packet_id: String,
    pub schema_version: i64,
    pub objective: String,
    pub sources: usize,
    pub claims: usize,
    pub uncertainties: usize,
    pub next_steps: usize,
    pub lineage_links: usize,
    pub sensitivity: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GetPacketResult {
    pub packet: PacketProjection,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PacketProjection {
    pub drawer_id: String,
    pub packet_id: String,
    pub schema_version: i64,
    pub future_schema: bool,
    pub objective: String,
    pub sources: Vec<PacketSourceProjection>,
    pub claims: Vec<PacketClaimProjection>,
    pub uncertainties: Vec<String>,
    pub next_steps: Vec<String>,
    pub provenance: PacketProvenanceProjection,
    pub lineage_links: Vec<LineageLinkProjection>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PacketSourceProjection {
    pub id: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PacketClaimProjection {
    pub id: String,
    pub statement: String,
    pub confidence: f64,
    pub supporting_source_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PacketProvenanceProjection {
    pub model: String,
    pub agent: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LineageLinkProjection {
    pub kind: LineageKind,
    pub target_packet_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ListPacketItem {
    pub drawer_id: String,
    pub packet_id: String,
    pub objective: String,
    pub model: String,
    pub agent: String,
    pub lineage_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ListPacketsResult {
    pub packets: Vec<ListPacketItem>,
    pub total: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LineageResult {
    pub root: String,
    pub antecedents: Vec<String>,
    pub count: usize,
}

/// Direct public-estate execution for the four typed packet operations.
pub struct PacketToolService<'a> {
    coordinator: &'a EstateCoordinator,
    handle: &'a EstateHandle,
    sensitivity_ledger: &'a SensitivityGrantLedger,
    now_millis: i64,
}

impl<'a> PacketToolService<'a> {
    pub fn new(
        coordinator: &'a EstateCoordinator,
        handle: &'a EstateHandle,
        sensitivity_ledger: &'a SensitivityGrantLedger,
        now_millis: i64,
    ) -> Self {
        Self { coordinator, handle, sensitivity_ledger, now_millis }
    }

    pub fn file(&self, request: FilePacketRequest) -> Result<FilePacketResult, PacketToolError> {
        let estate = self.estate()?;
        let mut frame = CaptureFrame::new(
            request.packet.encode_storage()?,
            CaptureChannel::Actuator,
            PACKET_ROOM,
            LatticeAnchor::udc(PACKET_UDC),
            PACKET_ADDED_BY,
            PACKET_EMBEDDING_MODEL,
        );
        frame.kind = ContentKind::StructuredJson;
        frame.wing = Some(request.wing.clone());
        frame.event_time = Some(self.now_millis);
        frame.sensitivity = request.sensitivity;
        let captured = estate.capture(frame, self.now_millis)
            .map_err(|error| PacketToolError::operational(format!("packet capture failed: {error}")))?;

        // The drawer is the durable write identity. Tunnels are a derived index:
        // each failure is intentionally ignored after a successful capture.
        for link in &request.packet.lineage_links {
            let mut tunnel = TunnelCaptureFrame::new(
                &request.wing,
                PACKET_ROOM,
                &request.wing,
                PACKET_ROOM,
                link.kind.label(),
                PACKET_ADDED_BY,
            );
            tunnel.source_drawer_id = Some(captured.id.clone());
            tunnel.target_drawer_id = Some(link.target_packet_id.clone());
            tunnel.kind = link.kind.tunnel_kind();
            tunnel.origin_class = TunnelOriginClass::Derived;
            let _ = estate.capture_tunnel(tunnel, self.now_millis);
        }
        Ok(FilePacketResult {
            drawer_id: captured.id,
            packet_id: request.packet.id,
            schema_version: request.packet.schema_version,
            objective: request.packet.objective,
            sources: request.packet.sources.len(),
            claims: request.packet.claims.len(),
            uncertainties: request.packet.uncertainties.len(),
            next_steps: request.packet.next_steps.len(),
            lineage_links: request.packet.lineage_links.len(),
            sensitivity: sensitivity_name(request.sensitivity).to_string(),
        })
    }

    pub fn get(&self, request: GetPacketRequest) -> Result<GetPacketResult, PacketToolError> {
        let wing = self.resolve_packet_wing(&request.drawer_id, request.wing.as_deref())?;
        let drawer = self.gated_drawers(&[request.drawer_id.clone()], &wing)?
            .into_iter()
            .find(|drawer| drawer.id == request.drawer_id)
            .ok_or_else(|| PacketToolError::not_found("packet not found"))?;
        let packet = WorkPacket::decode_storage(&drawer.content)
            .map_err(|_| PacketToolError::not_found("packet not found"))?;
        Ok(GetPacketResult { packet: packet_projection(drawer.id, packet) })
    }

    pub fn list(&self, request: ListPacketsRequest) -> Result<ListPacketsResult, PacketToolError> {
        let mut frame = self.packet_frame(&request.wing);
        frame.limit = Some(request.limit);
        frame.ordering = Ordering::ByCaptureTimeDesc;
        let drawers = self.estate()?.recall(frame, self.now_millis).collect_all();
        let packets: Vec<ListPacketItem> = drawers.into_iter()
            .filter(|drawer| provenance_visible(drawer))
            .filter_map(|drawer| WorkPacket::decode_storage(&drawer.content).ok().map(|packet| ListPacketItem {
                drawer_id: drawer.id,
                packet_id: packet.id,
                objective: packet.objective,
                model: packet.provenance.model,
                agent: packet.provenance.agent,
                lineage_count: packet.lineage_links.len(),
            }))
            .collect();
        let total = packets.len();
        Ok(ListPacketsResult { packets, total })
    }

    pub fn lineage(&self, request: LineageRequest) -> Result<LineageResult, PacketToolError> {
        let wing = self.resolve_packet_wing(&request.drawer_id, request.wing.as_deref())?;
        let root = self.get(GetPacketRequest {
            drawer_id: request.drawer_id.clone(),
            wing: Some(wing.clone()),
        })?;
        let mut visited = HashSet::from([root.packet.drawer_id]);
        let mut frontier = vec![request.drawer_id.clone()];
        let mut antecedents = Vec::new();
        for _ in 0..request.max_depth {
            if frontier.is_empty() {
                break;
            }
            // Gate every frontier before decoding its packet JSON. This makes a
            // hidden antecedent indistinguishable from a missing row and never
            // lets it influence a later traversal hop.
            let drawers = self.gated_drawers(&frontier, &wing)?;
            let mut next = Vec::new();
            for drawer in drawers {
                let Ok(packet) = WorkPacket::decode_storage(&drawer.content) else { continue };
                for link in packet.lineage_links {
                    if visited.insert(link.target_packet_id.clone()) {
                        next.push(link.target_packet_id.clone());
                    }
                }
            }
            if next.is_empty() {
                break;
            }
            // Authorize the emitted level before revealing IDs. Retain next's
            // encounter order after authorization so breadth-first survivor
            // order remains stable.
            let visible: HashSet<String> = self.gated_drawers(&next, &wing)?
                .into_iter().map(|drawer| drawer.id).collect();
            frontier = next.into_iter().filter(|id| visible.contains(id)).collect();
            antecedents.extend(frontier.iter().cloned());
        }
        let count = antecedents.len();
        Ok(LineageResult { root: request.drawer_id, antecedents, count })
    }

    fn estate(&self) -> Result<&locus_kit::estate::Estate, PacketToolError> {
        self.coordinator.estate_for(self.handle)
            .map_err(|error| PacketToolError::operational(format!("estate unavailable: {error:?}")))
    }

    fn resolve_packet_wing(&self, id: &str, requested: Option<&str>) -> Result<String, PacketToolError> {
        if let Some(wing) = requested { return Ok(wing.to_owned()); }
        let mut filters = vec![Filter::CurrentlyBelieve, Filter::InRoom(PACKET_ROOM.to_owned())];
        if let Some(ceiling) = self.sensitivity_ledger.ceiling_sensitivity(self.now_millis) {
            filters.push(Filter::SensitivityAtMost(ceiling));
        }
        let mut frame = RecallFrame::new(filters);
        frame.hydration_level = HydrationLevel::Full;
        let estate = self.estate()?;
        let result = estate.get_drawers_matching_frame(&[id.to_owned()], &frame)
            .map_err(|error| PacketToolError::operational(format!("packet read failed: {error}")))?;
        let drawer = result.admissible.into_iter().find(provenance_visible)
            .ok_or_else(|| PacketToolError::not_found("packet not found"))?;
        estate.resolve_drawer_node_names(&[drawer.parent_node_id.clone()])
            .map_err(|error| PacketToolError::operational(format!("packet placement read failed: {error}")))?
            .get(&drawer.parent_node_id).map(|(wing, _)| wing.clone())
            .filter(|wing| !wing.is_empty())
            .ok_or_else(|| PacketToolError::not_found("packet not found"))
    }

    fn packet_frame(&self, wing: &str) -> RecallFrame {
        let mut filters = vec![
            Filter::CurrentlyBelieve,
            Filter::InWing(wing.to_string()),
            Filter::InRoom(PACKET_ROOM.to_string()),
        ];
        if let Some(ceiling) = self.sensitivity_ledger.ceiling_sensitivity(self.now_millis) {
            filters.push(Filter::SensitivityAtMost(ceiling));
        }
        let mut frame = RecallFrame::new(filters);
        frame.hydration_level = HydrationLevel::Full;
        frame
    }

    fn gated_drawers(&self, ids: &[String], wing: &str) -> Result<Vec<Drawer>, PacketToolError> {
        let result = self.estate()?.get_drawers_matching_frame(ids, &self.packet_frame(wing))
            .map_err(|error| PacketToolError::operational(format!("packet read failed: {error}")))?;
        Ok(result.admissible.into_iter().filter(provenance_visible).collect())
    }
}

fn packet_projection(drawer_id: String, packet: WorkPacket) -> PacketProjection {
    let future_schema = packet.is_future_schema();
    PacketProjection {
        drawer_id,
        packet_id: packet.id,
        schema_version: packet.schema_version,
        future_schema,
        objective: packet.objective,
        sources: packet.sources.into_iter().map(|source| PacketSourceProjection {
            id: source.id,
            description: source.description,
            uri: source.uri,
            kind: source.kind,
        }).collect(),
        claims: packet.claims.into_iter().map(|claim| PacketClaimProjection {
            id: claim.id,
            statement: claim.statement,
            confidence: claim.confidence,
            supporting_source_ids: claim.supporting_source_ids,
        }).collect(),
        uncertainties: packet.uncertainties,
        next_steps: packet.next_steps,
        provenance: PacketProvenanceProjection {
            model: packet.provenance.model,
            agent: packet.provenance.agent,
            created_at: packet.provenance.created_at.0,
            updated_at: packet.provenance.updated_at.0,
        },
        lineage_links: packet.lineage_links.into_iter().map(|link| LineageLinkProjection {
            kind: link.kind,
            target_packet_id: link.target_packet_id,
        }).collect(),
    }
}

fn provenance_visible(drawer: &Drawer) -> bool {
    // Unknown capture-time values must not inherit the tolerant enum's Normal fallback.
    matches!((drawer.provenance >> 30) & 0x3f, 0 | 16)
}

#[cfg(test)]
mod provenance_gate_tests {
    use super::*;

    #[test]
    fn unknown_packet_provenance_never_inherits_normal_visibility() {
        let mut drawer = Drawer::new("packet", "private body", "room", "test", 1, "model");
        for raw in [1, 31, 32, 48, 63] {
            drawer.provenance = raw << 30;
            assert!(!provenance_visible(&drawer), "raw sensitivity {raw} must be refused");
        }
        for raw in [0, 16] {
            drawer.provenance = raw << 30;
            assert!(provenance_visible(&drawer));
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacketToolError {
    pub code: &'static str,
    pub path: String,
    pub message: String,
    pub retryable: bool,
}

impl PacketToolError {
    fn invalid(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: "invalid_argument", path: path.into(), message: message.into(), retryable: false }
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self { code: "packet_not_found", path: "drawer_id".to_string(), message: message.into(), retryable: false }
    }

    fn operational(message: impl Into<String>) -> Self {
        Self { code: "operation_failed", path: String::new(), message: message.into(), retryable: true }
    }
}

fn reject_unknown(args: &BTreeMap<String, Value>, allowed: &[&str]) -> Result<(), PacketToolError> {
    let allowed: HashSet<&str> = allowed.iter().copied().collect();
    if let Some(key) = args.keys().find(|key| !allowed.contains(key.as_str())) {
        return Err(PacketToolError::invalid(key, format!("unknown argument: {key}")));
    }
    Ok(())
}

fn required_string(args: &BTreeMap<String, Value>, key: &str) -> Result<String, PacketToolError> {
    let value = optional_string(args, key)?
        .ok_or_else(|| PacketToolError::invalid(key, format!("missing required string argument: {key}")))?;
    require_nonempty(&value, key)?;
    Ok(value)
}

fn optional_string(args: &BTreeMap<String, Value>, key: &str) -> Result<Option<String>, PacketToolError> {
    match args.get(key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(PacketToolError::invalid(key, format!("{key} must be a string"))),
    }
}

fn decode_string_array(value: Option<&Value>, path: &str) -> Result<Vec<String>, PacketToolError> {
    match value {
        None => Ok(Vec::new()),
        Some(Value::Array(values)) => values.iter().enumerate().map(|(index, value)| match value {
            Value::String(value) => Ok(value.clone()),
            _ => Err(PacketToolError::invalid(format!("{path}[{index}]"), "must be a string")),
        }).collect(),
        Some(_) => Err(PacketToolError::invalid(path, "must be an array of strings")),
    }
}

fn decode_sources(value: Option<&Value>) -> Result<Vec<PacketSource>, PacketToolError> {
    let Some(Value::Array(values)) = value else {
        return if value.is_none() { Ok(Vec::new()) } else { Err(PacketToolError::invalid("sources", "must be an array")) };
    };
    values.iter().enumerate().map(|(index, value)| {
        let object = value.as_object().ok_or_else(|| PacketToolError::invalid(format!("sources[{index}]"), "must be an object"))?;
        reject_unknown_json(object, &["description", "kind", "uri"])?;
        let description = required_json_string(object, "description", &format!("sources[{index}].description"))?;
        let kind = optional_json_string(object, "kind", &format!("sources[{index}].kind"))?.unwrap_or_else(|| "drawer".to_string());
        let uri = optional_json_string(object, "uri", &format!("sources[{index}].uri"))?;
        Ok(PacketSource { id: Uuid::new_v4().to_string(), description, uri, kind })
    }).collect()
}

fn decode_claims(value: Option<&Value>) -> Result<Vec<PacketClaim>, PacketToolError> {
    let Some(Value::Array(values)) = value else {
        return if value.is_none() { Ok(Vec::new()) } else { Err(PacketToolError::invalid("claims", "must be an array")) };
    };
    values.iter().enumerate().map(|(index, value)| {
        let object = value.as_object().ok_or_else(|| PacketToolError::invalid(format!("claims[{index}]"), "must be an object"))?;
        reject_unknown_json(object, &["statement", "confidence", "supportingSourceIDs"])?;
        let statement = required_json_string(object, "statement", &format!("claims[{index}].statement"))?;
        let confidence = match object.get("confidence") {
            None => 1.0,
            Some(Value::Number(value)) => value.as_f64().ok_or_else(|| PacketToolError::invalid(format!("claims[{index}].confidence"), "must be a finite number"))?,
            Some(_) => return Err(PacketToolError::invalid(format!("claims[{index}].confidence"), "must be a number")),
        };
        validate_confidence(confidence, &format!("claims[{index}].confidence"))?;
        let supporting_source_ids = match object.get("supportingSourceIDs") {
            None => Vec::new(),
            Some(Value::Array(values)) => values.iter().enumerate().map(|(source_index, value)| match value {
                Value::String(value) => Ok(value.clone()),
                _ => Err(PacketToolError::invalid(format!("claims[{index}].supportingSourceIDs[{source_index}]"), "must be a string")),
            }).collect::<Result<Vec<_>, _>>()?,
            Some(_) => return Err(PacketToolError::invalid(format!("claims[{index}].supportingSourceIDs"), "must be an array")),
        };
        Ok(PacketClaim { id: Uuid::new_v4().to_string(), statement, confidence, supporting_source_ids })
    }).collect()
}

fn decode_lineage_links(value: Option<&Value>) -> Result<Vec<LineageLink>, PacketToolError> {
    let Some(Value::Array(values)) = value else {
        return if value.is_none() { Ok(Vec::new()) } else { Err(PacketToolError::invalid("lineage_links", "must be an array")) };
    };
    values.iter().enumerate().map(|(index, value)| {
        let object = value.as_object().ok_or_else(|| PacketToolError::invalid(format!("lineage_links[{index}]"), "must be an object"))?;
        reject_unknown_json(object, &["kind", "targetPacketID"])?;
        let kind = match required_json_string(object, "kind", &format!("lineage_links[{index}].kind"))?.as_str() {
            "derivesFrom" => LineageKind::DerivesFrom,
            "respondsTo" => LineageKind::RespondsTo,
            _ => return Err(PacketToolError::invalid(format!("lineage_links[{index}].kind"), "must be derivesFrom or respondsTo")),
        };
        let target_packet_id = canonical_uuid(
            &required_json_string(object, "targetPacketID", &format!("lineage_links[{index}].targetPacketID"))?,
            &format!("lineage_links[{index}].targetPacketID"),
        )?;
        Ok(LineageLink { kind, target_packet_id })
    }).collect()
}

fn optional_sensitivity(args: &BTreeMap<String, Value>) -> Result<Option<AdjectiveSensitivity>, PacketToolError> {
    let Some(value) = args.get("sensitivity") else { return Ok(None) };
    let Value::String(value) = value else { return Err(PacketToolError::invalid("sensitivity", "sensitivity must be a string")) };
    let sensitivity = match value.as_str() {
        "normal" => AdjectiveSensitivity::Normal,
        "elevated" => AdjectiveSensitivity::Elevated,
        "restricted" => AdjectiveSensitivity::Restricted,
        "secret" => AdjectiveSensitivity::Secret,
        _ => return Err(PacketToolError::invalid("sensitivity", "sensitivity must be normal, elevated, restricted, or secret")),
    };
    Ok(Some(sensitivity))
}

fn sensitivity_rank(value: AdjectiveSensitivity) -> i64 { value.raw_value() }

fn sensitivity_name(value: AdjectiveSensitivity) -> &'static str {
    match value {
        AdjectiveSensitivity::Normal => "normal",
        AdjectiveSensitivity::Elevated => "elevated",
        AdjectiveSensitivity::Restricted => "restricted",
        AdjectiveSensitivity::Secret => "secret",
    }
}

fn reject_unknown_json(object: &serde_json::Map<String, Value>, allowed: &[&str]) -> Result<(), PacketToolError> {
    let allowed: HashSet<&str> = allowed.iter().copied().collect();
    if let Some(key) = object.keys().find(|key| !allowed.contains(key.as_str())) {
        return Err(PacketToolError::invalid(key, format!("unknown argument: {key}")));
    }
    Ok(())
}

fn required_json_string(object: &serde_json::Map<String, Value>, key: &str, path: &str) -> Result<String, PacketToolError> {
    let value = optional_json_string(object, key, path)?
        .ok_or_else(|| PacketToolError::invalid(path, format!("missing required string argument: {key}")))?;
    require_nonempty(&value, path)?;
    Ok(value)
}

fn optional_json_string(object: &serde_json::Map<String, Value>, key: &str, path: &str) -> Result<Option<String>, PacketToolError> {
    match object.get(key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(PacketToolError::invalid(path, "must be a string")),
    }
}

fn require_nonempty(value: &str, path: &str) -> Result<(), PacketToolError> {
    if value.is_empty() { Err(PacketToolError::invalid(path, "must not be empty")) } else { Ok(()) }
}

fn validate_confidence(value: f64, path: &str) -> Result<(), PacketToolError> {
    if value.is_finite() && (0.0..=1.0).contains(&value) { Ok(()) } else { Err(PacketToolError::invalid(path, "confidence must be a finite number from 0.0 through 1.0")) }
}

fn canonical_uuid(value: &str, path: &str) -> Result<String, PacketToolError> {
    Uuid::parse_str(value).map(|uuid| uuid.to_string())
        .map_err(|_| PacketToolError::invalid(path, "must be a UUID"))
}

fn parse_iso8601_millis(value: &str) -> Result<i64, &'static str> {
    let bytes = value.as_bytes();
    if bytes.len() < 20 || bytes.get(4) != Some(&b'-') || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T') || bytes.get(13) != Some(&b':') || bytes.get(16) != Some(&b':') {
        return Err("timestamp must be an ISO-8601 date-time");
    }
    let year = digits(bytes, 0, 4)?;
    let month = digits(bytes, 5, 7)?;
    let day = digits(bytes, 8, 10)?;
    let hour = digits(bytes, 11, 13)?;
    let minute = digits(bytes, 14, 16)?;
    let second = digits(bytes, 17, 19)?;
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month)
        || hour > 23 || minute > 59 || second > 59 { return Err("timestamp contains an invalid calendar value"); }
    let mut cursor = 19;
    let mut millis = 0i64;
    if bytes.get(cursor) == Some(&b'.') {
        cursor += 1;
        let fraction_start = cursor;
        while bytes.get(cursor).is_some_and(|byte| byte.is_ascii_digit()) { cursor += 1; }
        if cursor == fraction_start { return Err("timestamp fraction must contain digits"); }
        let fraction = &bytes[fraction_start..cursor];
        millis = fraction.iter().take(3).fold(0, |value, digit| value * 10 + i64::from(digit - b'0'));
        for _ in fraction.len()..3 { millis *= 10; }
    }
    let offset_seconds = match bytes.get(cursor) {
        Some(b'Z') if cursor + 1 == bytes.len() => 0,
        Some(sign @ (b'+' | b'-')) if cursor + 6 == bytes.len() && bytes.get(cursor + 3) == Some(&b':') => {
            let offset_hour = digits(bytes, cursor + 1, cursor + 3)?;
            let offset_minute = digits(bytes, cursor + 4, cursor + 6)?;
            if offset_hour > 23 || offset_minute > 59 { return Err("timestamp offset is invalid"); }
            let seconds = (offset_hour * 60 + offset_minute) * 60;
            if *sign == b'+' { seconds } else { -seconds }
        }
        _ => return Err("timestamp must end in Z or a numeric UTC offset"),
    };
    let days = days_from_civil(year, month, day);
    Ok(((days * 86_400 + hour * 3_600 + minute * 60 + second - offset_seconds) * 1_000) + millis)
}

fn digits(bytes: &[u8], start: usize, end: usize) -> Result<i64, &'static str> {
    bytes.get(start..end).ok_or("timestamp is truncated")?.iter().try_fold(0i64, |value, digit| {
        if digit.is_ascii_digit() { Ok(value * 10 + i64::from(digit - b'0')) } else { Err("timestamp contains a non-numeric calendar field") }
    })
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month { 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31, 4 | 6 | 9 | 11 => 30, 2 if is_leap_year(year) => 29, 2 => 28, _ => 0 }
}
fn is_leap_year(year: i64) -> bool { year.rem_euclid(4) == 0 && (year.rem_euclid(100) != 0 || year.rem_euclid(400) == 0) }

// Howard Hinnant's civil-date conversion, expressed with Euclidean integer
// arithmetic so dates before 1970 remain valid ISO-8601 instants.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let mp = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn format_epoch_millis(epoch_millis: i64) -> String {
    let seconds = epoch_millis.div_euclid(1_000);
    let millis = epoch_millis.rem_euclid(1_000);
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let time = seconds.rem_euclid(86_400);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z", time / 3_600, (time / 60) % 60, time % 60, millis)
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    (year + i64::from(month <= 2), month, day)
}
