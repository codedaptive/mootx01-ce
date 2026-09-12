//! Typed v2 memory mutation core.
//!
//! This unregistered module owns seven write operations and calls the lower
//! estate/coordinator verbs directly.  It deliberately has no dependency on
//! the v1 dispatcher, text result parser, sensitivity ledger, or v1 memory
//! operation context.  Surface wiring owns catalogue admission and rendering.

use std::sync::{Arc, Mutex};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::{
    adjectives::{AdjectiveExportability, AdjectiveSensitivity},
    drawer_store::SUBJECT_LENGTH_CONTRACT,
    frames::{MutationKind, TunnelCaptureFrame},
    tunnel_operational::TunnelKind,
};
use uuid::Uuid;

use crate::jsonrpc::JsonValue;

use super::codec::{
    optional_string, optional_uuid, required_bool, required_string, required_uuid, strict_object, V2DecodeResult,
    V2InvalidArgument,
};

pub const UPDATE_MEMORY_TOOL: &str = "moot_update_memory";
pub const WITHDRAW_MEMORY_TOOL: &str = "moot_withdraw_memory";
pub const ERASE_MEMORY_TOOL: &str = "moot_erase_memory";
pub const CONFIRM_MEMORY_TOOL: &str = "moot_confirm_memory";
pub const MOVE_MEMORY_TOOL: &str = "moot_move_memory";
pub const LINK_MEMORIES_TOOL: &str = "moot_link_memories";
pub const REVIEW_TUNNEL_TOOL: &str = "moot_review_tunnel";

/// Stable public operation identity.  These names are the only bridge from
/// the selected catalogue to this direct typed service.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2MemoryMutationOperation {
    UpdateMemory,
    WithdrawMemory,
    EraseMemory,
    ConfirmMemory,
    MoveMemory,
    LinkMemories,
    ReviewTunnel,
}

impl V2MemoryMutationOperation {
    pub const fn tool_name(self) -> &'static str {
        match self {
            Self::UpdateMemory => UPDATE_MEMORY_TOOL,
            Self::WithdrawMemory => WITHDRAW_MEMORY_TOOL,
            Self::EraseMemory => ERASE_MEMORY_TOOL,
            Self::ConfirmMemory => CONFIRM_MEMORY_TOOL,
            Self::MoveMemory => MOVE_MEMORY_TOOL,
            Self::LinkMemories => LINK_MEMORIES_TOOL,
            Self::ReviewTunnel => REVIEW_TUNNEL_TOOL,
        }
    }
}

/// Authority output for one admitted write.  It contains only the selected
/// estate, caller audit binding, and authority-owned clock; it intentionally
/// carries no drawer visibility, sensitivity ceiling, or v1 request context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MemoryMutationAdmission {
    pub estate_id: Uuid,
    pub estate_handle: EstateHandle,
    pub caller_binding: String,
    pub now_millis: i64,
    pub authorization_generation: String,
    /// Sensitivity ceiling for this caller.  A memory whose sensitivity
    /// adjective exceeds this ceiling is treated as absent for every write
    /// operation, producing an identical `memory_not_found` refusal regardless
    /// of whether the row exists.  Both outcomes are indistinguishable to the
    /// caller so neither can oracle the other.
    pub maximum_sensitivity: AdjectiveSensitivity,
}

/// Surface-owned authority.  A refusal is intentionally indistinguishable
/// from a lower unavailable result at the public renderer, preventing an
/// operation from becoming an existence oracle.
pub trait V2MemoryMutationAuthority: Send + Sync {
    fn admit(
        &self,
        operation: V2MemoryMutationOperation,
        requested_estate_id: Option<Uuid>,
    ) -> Result<V2MemoryMutationAdmission, ()>;

    fn revalidate(&self, admission: &V2MemoryMutationAdmission) -> Result<(), ()>;

    /// Resolve a caller-supplied UUID to a confirmed, admissible storage UUID.
    /// Returns `Err(NotFound)` when the ID does not exist OR when the row's
    /// sensitivity exceeds `admission.maximum_sensitivity`.  Both cases are
    /// indistinguishable to the caller (oracle-closure).
    fn resolve_memory(
        &self,
        admission: &V2MemoryMutationAdmission,
        memory_id: Uuid,
    ) -> Result<Uuid, V2MemoryMutationError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2UpdateMutation {
    Confirm,
    Reject,
    Contest,
    Resolve,
    Supersede,
    Revive,
    Accept,
    SetSubject(String),
    CorrectSensitivity(AdjectiveSensitivity),
    CorrectExportability(AdjectiveExportability),
}

impl V2UpdateMutation {
    fn lower(&self) -> MutationKind {
        match self {
            Self::Confirm => MutationKind::Confirm,
            Self::Reject => MutationKind::Reject,
            Self::Contest => MutationKind::Contest,
            Self::Resolve => MutationKind::Resolve,
            Self::Supersede => MutationKind::Supersede,
            Self::Revive => MutationKind::Revive,
            Self::Accept => MutationKind::Accept,
            Self::SetSubject(subject) => MutationKind::SetSubject(subject.clone()),
            Self::CorrectSensitivity(value) => MutationKind::CorrectSensitivity(*value),
            Self::CorrectExportability(value) => MutationKind::CorrectExportability(*value),
        }
    }

    /// Returns the wire-format mutation name matching the string that
    /// decode_update_mutation accepts.  Used to populate the moot_update_memory
    /// response payload so the emitted JSON matches the declared output schema
    /// (`memory_id` + `mutation`).
    pub fn wire_name(&self) -> &'static str {
        match self {
            Self::Confirm => "confirm",
            Self::Reject => "reject",
            Self::Contest => "contest",
            Self::Resolve => "resolve",
            Self::Supersede => "supersede",
            Self::Revive => "revive",
            Self::Accept => "accept",
            Self::SetSubject(_) => "set_subject",
            Self::CorrectSensitivity(_) => "correct_sensitivity",
            Self::CorrectExportability(_) => "correct_exportability",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2UpdateMemoryRequest {
    pub memory_id: Uuid,
    pub mutation: V2UpdateMutation,
    pub note: Option<String>,
    pub estate_id: Option<Uuid>,
}

impl V2UpdateMemoryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, [
            "memory_id", "mutation", "subject", "sensitivity", "exportability", "note", "estate_id",
        ])?;
        let subject = optional_string(object, "subject")?;
        let sensitivity = optional_string(object, "sensitivity")?;
        let exportability = optional_string(object, "exportability")?;
        let note = optional_string(object, "note")?.map(str::to_owned);
        let mutation_name = required_string(object, "mutation")?;
        let mutation = decode_update_mutation(mutation_name, subject, sensitivity, exportability)?;
        if subject.is_some() && mutation_name != "set_subject" {
            return Err(V2InvalidArgument::new("$.subject", "is only valid for set_subject"));
        }
        if sensitivity.is_some() && mutation_name != "correct_sensitivity" {
            return Err(V2InvalidArgument::new("$.sensitivity", "is only valid for correct_sensitivity"));
        }
        if exportability.is_some() && mutation_name != "correct_exportability" {
            return Err(V2InvalidArgument::new("$.exportability", "is only valid for correct_exportability"));
        }
        if note.is_some() && mutation_name == "confirm" {
            return Err(V2InvalidArgument::new(
                "$.note",
                "is not accepted for confirm because the lower confirmation verb does not persist it",
            ));
        }
        Ok(Self { memory_id: required_uuid(object, "memory_id")?, mutation, note, estate_id: optional_uuid(object, "estate_id")? })
    }
}

fn decode_update_mutation(
    value: &str,
    subject: Option<&str>,
    sensitivity: Option<&str>,
    exportability: Option<&str>,
) -> V2DecodeResult<V2UpdateMutation> {
    let simple = match value {
        "confirm" => Some(V2UpdateMutation::Confirm),
        "reject" => Some(V2UpdateMutation::Reject),
        "contest" => Some(V2UpdateMutation::Contest),
        "resolve" => Some(V2UpdateMutation::Resolve),
        "supersede" => Some(V2UpdateMutation::Supersede),
        "revive" => Some(V2UpdateMutation::Revive),
        "accept" => Some(V2UpdateMutation::Accept),
        _ => None,
    };
    if let Some(mutation) = simple {
        return Ok(mutation);
    }
    match value {
        "set_subject" => match subject {
            Some(raw) if raw.chars().count() <= SUBJECT_LENGTH_CONTRACT && !raw.trim().is_empty() => {
                Ok(V2UpdateMutation::SetSubject(raw.trim().to_owned()))
            }
            _ => Err(V2InvalidArgument::new(
                "$.subject",
                "is required and must contain 1 to 120 Unicode scalars before trimming for set_subject",
            )),
        },
        "correct_sensitivity" => match sensitivity {
            Some("normal") => Ok(V2UpdateMutation::CorrectSensitivity(AdjectiveSensitivity::Normal)),
            Some("elevated") => Ok(V2UpdateMutation::CorrectSensitivity(AdjectiveSensitivity::Elevated)),
            Some("restricted") => Ok(V2UpdateMutation::CorrectSensitivity(AdjectiveSensitivity::Restricted)),
            Some("secret") => Ok(V2UpdateMutation::CorrectSensitivity(AdjectiveSensitivity::Secret)),
            _ => Err(V2InvalidArgument::new("$.sensitivity", "must be normal, elevated, restricted, or secret for correct_sensitivity")),
        },
        "correct_exportability" => match exportability {
            Some("private") => Ok(V2UpdateMutation::CorrectExportability(AdjectiveExportability::Private)),
            Some("public") => Ok(V2UpdateMutation::CorrectExportability(AdjectiveExportability::Public)),
            _ => Err(V2InvalidArgument::new("$.exportability", "must be private or public for correct_exportability")),
        },
        _ => Err(V2InvalidArgument::new("$.mutation", "is not a supported typed memory mutation")),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2WithdrawMemoryRequest { pub memory_id: Uuid, pub reason: Option<String>, pub estate_id: Option<Uuid> }
impl V2WithdrawMemoryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["memory_id", "reason", "estate_id"])?;
        Ok(Self { memory_id: required_uuid(object, "memory_id")?, reason: optional_string(object, "reason")?.map(str::to_owned), estate_id: optional_uuid(object, "estate_id")? })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2EraseMemoryRequest {
    pub memory_id: Uuid,
    pub confirmation: bool,
    pub reason: Option<String>,
    pub estate_id: Option<Uuid>,
}
impl V2EraseMemoryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["memory_id", "confirmation", "reason", "estate_id"])?;
        let confirmation = required_bool(object, "confirmation")?;
        if !confirmation { return Err(V2InvalidArgument::new("$.confirmation", "must be true")); }
        Ok(Self {
            memory_id: required_uuid(object, "memory_id")?,
            confirmation,
            reason: optional_string(object, "reason")?.map(str::to_owned),
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ConfirmMemoryRequest { pub memory_id: Uuid, pub estate_id: Option<Uuid> }
impl V2ConfirmMemoryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["memory_id", "estate_id"])?;
        Ok(Self { memory_id: required_uuid(object, "memory_id")?, estate_id: optional_uuid(object, "estate_id")? })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MoveMemoryRequest { pub memory_id: Uuid, pub wing: String, pub room: String, pub estate_id: Option<Uuid> }
impl V2MoveMemoryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["memory_id", "wing", "room", "estate_id"])?;
        let wing = required_nonempty(object, "wing")?;
        let room = required_nonempty(object, "room")?;
        Ok(Self { memory_id: required_uuid(object, "memory_id")?, wing, room, estate_id: optional_uuid(object, "estate_id")? })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2LinkMemoriesRequest {
    pub from_id: Uuid,
    pub to_id: Uuid,
    pub relationship: String,
    pub confidence: Option<String>,
    pub evidence: Option<String>,
    pub estate_id: Option<Uuid>,
}
impl V2LinkMemoriesRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["from_id", "to_id", "relationship", "confidence", "evidence", "estate_id"])?;
        let from_id = required_uuid(object, "from_id")?;
        let to_id = required_uuid(object, "to_id")?;
        if from_id == to_id { return Err(V2InvalidArgument::new("$.to_id", "must differ from $.from_id")); }
        let relationship = required_nonempty(object, "relationship")?;
        if !matches!(relationship.as_str(),
            "blocks" | "contradicts" | "covers" | "derives_from" | "elaborates"
            | "exemplifies" | "extends" | "precedes" | "references" | "refines"
            | "relates" | "responds_to" | "supersedes" | "supports" | "validates"
        ) {
            return Err(V2InvalidArgument::new("$.relationship", "unsupported relationship"));
        }
        Ok(Self {
            from_id, to_id, relationship,
            confidence: optional_string(object, "confidence")?.map(str::to_owned),
            evidence: optional_string(object, "evidence")?.map(str::to_owned),
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2TunnelDecision { Accept, Endorse, Reject }
/// The reviewer identity recorded in the review ledger.  Edge activation is
/// user-only, so this is the value the `accept` gate reads.
pub const USER_REVIEWER: &str = "user";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ReviewTunnelRequest { pub tunnel_id: Uuid, pub decision: V2TunnelDecision, pub note: Option<String>, pub reviewed_by: String, pub estate_id: Option<Uuid> }
impl V2ReviewTunnelRequest {
    /// True when the reviewer is the user rather than a model.
    pub fn is_user_reviewer(&self) -> bool { self.reviewed_by == USER_REVIEWER }

    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["tunnel_id", "decision", "note", "reviewed_by", "estate_id"])?;
        let decision = match required_string(object, "decision")? {
            "accept" => V2TunnelDecision::Accept,
            "endorse" => V2TunnelDecision::Endorse,
            "reject" => V2TunnelDecision::Reject,
            _ => return Err(V2InvalidArgument::new("$.decision", "must be accept, endorse, or reject")),
        };
        // An explicitly empty reviewed_by is a caller error, not a silent
        // fallback to the user identity — that would turn a typo into an edge
        // activation.
        let reviewed_by = match optional_string(object, "reviewed_by")? {
            None => USER_REVIEWER.to_owned(),
            Some(raw) if raw.trim().is_empty() => {
                return Err(V2InvalidArgument::new("$.reviewed_by", "must be a non-empty string"))
            }
            Some(raw) => raw.to_owned(),
        };
        // Edge activation is user-only.  Models endorse or reject; neither
        // settles the edge, so a machine can never ratify another machine's
        // inference.  Checked at decode so the refusal names the argument.
        if matches!(decision, V2TunnelDecision::Accept) && reviewed_by != USER_REVIEWER {
            return Err(V2InvalidArgument::new(
                "$.reviewed_by",
                "edge activation is user-only: decision 'accept' requires reviewed_by 'user'; model reviewers use 'endorse' or 'reject'",
            ));
        }
        Ok(Self { tunnel_id: required_uuid(object, "tunnel_id")?, decision, note: optional_string(object, "note")?.map(str::to_owned), reviewed_by, estate_id: optional_uuid(object, "estate_id")? })
    }
}

fn required_nonempty(object: &std::collections::BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<String> {
    let value = required_string(object, key)?;
    if value.is_empty() { Err(V2InvalidArgument::new(format!("$.{key}"), "must not be empty")) } else { Ok(value.to_owned()) }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2MemoryMutationOutcome { Updated, Withdrawn, Erased, ErasedPartially, Confirmed, Moved, Linked, TunnelAccepted, TunnelEndorsed, TunnelRejected }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2TunnelReviewReceipt {
    Endorsed { new_endorser: bool, distinct_endorsers: usize, contested: bool },
    Settled { withdrawn: bool, contested: bool },
}

/// Per-operation response data required to render the schema-declared output
/// key set for each non-review mutation.  The surface renderer matches on this
/// to emit exactly the `properties` declared in `remaining_data_schema`
/// (catalog.rs), and nothing else.  Review operations use `tunnel_review`
/// instead of this enum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2MutationResponsePayload {
    /// moot_withdraw_memory: schema declares only `memory_id`.
    Withdraw,
    /// moot_erase_memory: schema declares `memory_id`, `outcome`, and
    /// `refused_sibling_memory_ids`.  `outcome` and `refused_sibling_ids`
    /// live in `V2MemoryMutationResult` directly; this variant carries no
    /// extra fields.
    Erase,
    /// moot_confirm_memory: schema declares `memory_id` and `mutation` (the
    /// constant string `"confirm"`).
    Confirm,
    /// moot_move_memory: schema declares `memory_id` and `placement` with
    /// `wing` and `room` sub-keys.
    Move { wing: String, room: String },
    /// moot_link_memories: schema declares `tunnel_id`, `from_id`, `to_id`,
    /// `kind`, and `lifecycle`.  `tunnel_id` lives in
    /// `V2MemoryMutationResult`; the remaining four live here.
    Link { from_id: Uuid, to_id: Uuid, kind: String, lifecycle: String },
    /// moot_update_memory: schema declares `memory_id` and `mutation` (the
    /// wire-format mutation name string, e.g. `"reject"`, `"set_subject"`).
    Update { mutation: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MemoryMutationResult {
    pub operation: V2MemoryMutationOperation,
    pub outcome: V2MemoryMutationOutcome,
    pub memory_id: Option<Uuid>,
    pub tunnel_id: Option<Uuid>,
    pub tunnel_review: Option<V2TunnelReviewReceipt>,
    /// IDs of lineage siblings the audit gate refused to tombstone. Empty for
    /// a full erasure (outcome == Erased); non-empty for a partial erasure
    /// (outcome == ErasedPartially). Lowercased at the CoordinatorMemoryMutationLower
    /// boundary so callers do not need to normalize. Non-erase operations always
    /// carry an empty vec.
    pub refused_sibling_ids: Vec<String>,
    /// Per-operation response payload for the schema-declared output key set.
    /// Set by every non-review service method.  Review operations populate
    /// `tunnel_review` instead.
    pub payload: Option<V2MutationResponsePayload>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2MemoryMutationError {
    /// The mutation cannot be applied, or the estate is unreachable.
    Unavailable,
    /// The mutation landed but the readback confirmation failed.
    OutcomeUnverified(V2MemoryMutationOperation),
    /// No row matched the requested ID, OR the row exists but sits above the
    /// caller's sensitivity ceiling.  Both conditions produce this variant so
    /// neither can be distinguished by the caller (oracle-closure).
    NotFound,
}

/// Direct lower-kit interface.  `CoordinatorMemoryMutationLower` is the only
/// production implementation; keeping this narrow trait makes the typed
/// service testable without a legacy JSON/text adapter.
pub trait V2MemoryMutationLower: Send + Sync {
    fn mutate(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, mutation: &V2UpdateMutation, note: Option<&str>) -> Result<(), ()>;
    fn withdraw(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, reason: Option<&str>) -> Result<(), ()>;
    /// Returns the IDs of lineage siblings the audit gate refused to tombstone
    /// (lowercased). An empty vec means a full erasure; a non-empty vec means
    /// a partial erasure. The caller must return `Err(())` for any estate error.
    fn erase(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, confirmation: bool, reason: Option<&str>) -> Result<Vec<String>, ()>;
    fn move_memory(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, wing: &str, room: &str) -> Result<(), ()>;
    fn link(&self, admission: &V2MemoryMutationAdmission, request: &V2LinkMemoriesRequest) -> Result<Uuid, ()>;
    fn review(&self, admission: &V2MemoryMutationAdmission, tunnel_id: Uuid, decision: V2TunnelDecision, note: Option<&str>, reviewed_by: &str) -> Result<V2TunnelReviewReceipt, ()>;
}

pub struct V2MemoryMutationService<A, L> { authority: A, lower: L }
impl<A, L> V2MemoryMutationService<A, L> { pub fn new(authority: A, lower: L) -> Self { Self { authority, lower } } }

impl<A: V2MemoryMutationAuthority, L: V2MemoryMutationLower> V2MemoryMutationService<A, L> {
    pub fn update(&self, request: V2UpdateMemoryRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::UpdateMemory, request.estate_id)?;
        self.authority.resolve_memory(&admitted, request.memory_id)?;
        self.lower.mutate(&admitted, request.memory_id, &request.mutation, request.note.as_deref()).map_err(|_| V2MemoryMutationError::Unavailable)?;
        // Capture the wire name before finish() so the payload carries the mutation
        // string that the declared output schema requires (`memory_id` + `mutation`).
        let mutation_wire = request.mutation.wire_name().to_owned();
        let mut result = self.finish(admitted, V2MemoryMutationOperation::UpdateMemory, V2MemoryMutationOutcome::Updated, Some(request.memory_id), None)?;
        result.payload = Some(V2MutationResponsePayload::Update { mutation: mutation_wire });
        Ok(result)
    }
    pub fn withdraw(&self, request: V2WithdrawMemoryRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::WithdrawMemory, request.estate_id)?;
        self.authority.resolve_memory(&admitted, request.memory_id)?;
        self.lower.withdraw(&admitted, request.memory_id, request.reason.as_deref()).map_err(|_| V2MemoryMutationError::Unavailable)?;
        let mut result = self.finish(admitted, V2MemoryMutationOperation::WithdrawMemory, V2MemoryMutationOutcome::Withdrawn, Some(request.memory_id), None)?;
        // Declared schema: { memory_id }.
        result.payload = Some(V2MutationResponsePayload::Withdraw);
        Ok(result)
    }
    pub fn erase(&self, request: V2EraseMemoryRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::EraseMemory, request.estate_id)?;
        self.authority.resolve_memory(&admitted, request.memory_id)?;
        let refused_ids = self.lower.erase(&admitted, request.memory_id, request.confirmation, request.reason.as_deref()).map_err(|_| V2MemoryMutationError::Unavailable)?;
        let outcome = if refused_ids.is_empty() { V2MemoryMutationOutcome::Erased } else { V2MemoryMutationOutcome::ErasedPartially };
        let mut result = self.finish(admitted, V2MemoryMutationOperation::EraseMemory, outcome, Some(request.memory_id), None)?;
        result.refused_sibling_ids = refused_ids;
        // Declared schema: { memory_id, outcome, refused_sibling_memory_ids }.
        // outcome and refused_sibling_ids are already on the result; the payload
        // variant signals the renderer to emit those three keys only.
        result.payload = Some(V2MutationResponsePayload::Erase);
        Ok(result)
    }
    pub fn confirm(&self, request: V2ConfirmMemoryRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::ConfirmMemory, request.estate_id)?;
        self.authority.resolve_memory(&admitted, request.memory_id)?;
        self.lower.mutate(&admitted, request.memory_id, &V2UpdateMutation::Confirm, None).map_err(|_| V2MemoryMutationError::Unavailable)?;
        let mut result = self.finish(admitted, V2MemoryMutationOperation::ConfirmMemory, V2MemoryMutationOutcome::Confirmed, Some(request.memory_id), None)?;
        // Declared schema: { memory_id, mutation } where mutation is const "confirm".
        result.payload = Some(V2MutationResponsePayload::Confirm);
        Ok(result)
    }
    pub fn move_memory(&self, request: V2MoveMemoryRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::MoveMemory, request.estate_id)?;
        self.authority.resolve_memory(&admitted, request.memory_id)?;
        self.lower.move_memory(&admitted, request.memory_id, &request.wing, &request.room).map_err(|_| V2MemoryMutationError::Unavailable)?;
        let mut result = self.finish(admitted, V2MemoryMutationOperation::MoveMemory, V2MemoryMutationOutcome::Moved, Some(request.memory_id), None)?;
        // Declared schema: { memory_id, placement } where placement is { wing, room }.
        // request.wing and request.room are borrowed by the lower call above but still
        // owned by request, so they can be moved into the payload here.
        result.payload = Some(V2MutationResponsePayload::Move { wing: request.wing, room: request.room });
        Ok(result)
    }
    pub fn link(&self, request: V2LinkMemoriesRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::LinkMemories, request.estate_id)?;
        // Capture link payload fields before the lower call borrows request.
        let from_id = request.from_id;
        let to_id = request.to_id;
        let kind = request.relationship.clone();
        let tunnel_id = self.lower.link(&admitted, &request).map_err(|_| V2MemoryMutationError::Unavailable)?;
        let mut result = self.finish(admitted, V2MemoryMutationOperation::LinkMemories, V2MemoryMutationOutcome::Linked, None, Some(tunnel_id))?;
        // Declared schema: { tunnel_id, from_id, to_id, kind, lifecycle }.
        // The Rust request has no proposed flag; the lower always creates active tunnels.
        result.payload = Some(V2MutationResponsePayload::Link {
            from_id,
            to_id,
            kind,
            lifecycle: "active".to_owned(),
        });
        Ok(result)
    }
    pub fn review(&self, request: V2ReviewTunnelRequest) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        let admitted = self.admit(V2MemoryMutationOperation::ReviewTunnel, request.estate_id)?;
        let tunnel_review = self.lower.review(&admitted, request.tunnel_id, request.decision, request.note.as_deref(), &request.reviewed_by).map_err(|_| V2MemoryMutationError::Unavailable)?;
        let outcome = match request.decision {
            V2TunnelDecision::Accept => V2MemoryMutationOutcome::TunnelAccepted,
            V2TunnelDecision::Endorse => V2MemoryMutationOutcome::TunnelEndorsed,
            V2TunnelDecision::Reject => V2MemoryMutationOutcome::TunnelRejected,
        };
        let mut result = self.finish(admitted, V2MemoryMutationOperation::ReviewTunnel, outcome, None, Some(request.tunnel_id))?;
        result.tunnel_review = Some(tunnel_review);
        Ok(result)
    }
    fn admit(&self, operation: V2MemoryMutationOperation, estate_id: Option<Uuid>) -> Result<V2MemoryMutationAdmission, V2MemoryMutationError> { self.authority.admit(operation, estate_id).map_err(|_| V2MemoryMutationError::Unavailable) }
    fn finish(&self, admission: V2MemoryMutationAdmission, operation: V2MemoryMutationOperation, outcome: V2MemoryMutationOutcome, memory_id: Option<Uuid>, tunnel_id: Option<Uuid>) -> Result<V2MemoryMutationResult, V2MemoryMutationError> {
        self.authority.revalidate(&admission).map_err(|_| V2MemoryMutationError::OutcomeUnverified(operation))?;
        // refused_sibling_ids is set by the caller for erase operations; all other
        // operations carry an empty vec.  payload is set by each service method
        // after finish() returns so each operation carries its schema-declared keys.
        Ok(V2MemoryMutationResult { operation, outcome, memory_id, tunnel_id, tunnel_review: None, refused_sibling_ids: Vec::new(), payload: None })
    }
}

/// Production direct lower adapter.  It does not call `interface_tools` or
/// resolve an item for display before acting; all lower errors are collapsed by
/// the typed service to avoid differentiating absent from inaccessible state.
pub struct CoordinatorMemoryMutationLower { coordinator: Arc<Mutex<EstateCoordinator>> }
impl CoordinatorMemoryMutationLower { pub fn new(coordinator: Arc<Mutex<EstateCoordinator>>) -> Self { Self { coordinator } } }

impl V2MemoryMutationLower for CoordinatorMemoryMutationLower {
    fn mutate(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, mutation: &V2UpdateMutation, note: Option<&str>) -> Result<(), ()> {
        self.coordinator.lock().map_err(|_| ())?.mutate(&admission.estate_handle, &memory_id.to_string(), mutation.lower(), note).map_err(|_| ())
    }
    fn withdraw(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, reason: Option<&str>) -> Result<(), ()> {
        self.coordinator.lock().map_err(|_| ())?.withdraw(&admission.estate_handle, &memory_id.to_string(), reason, admission.now_millis).map_err(|_| ())
    }
    fn erase(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, confirmation: bool, reason: Option<&str>) -> Result<Vec<String>, ()> {
        let outcome = self.coordinator.lock().map_err(|_| ())?.expunge(&admission.estate_handle, &memory_id.to_string(), reason.unwrap_or(""), confirmation, admission.now_millis).map_err(|_| ())?;
        // D8: lowercase the ids at the lower boundary so every upstream layer
        // receives a normalized form without re-normalizing. Mirrors the Swift
        // `refusedSiblingIDs.map { $0.lowercased() }` at the same boundary.
        Ok(outcome.refused_sibling_ids.iter().map(|s| s.to_lowercase()).collect())
    }
    fn move_memory(&self, admission: &V2MemoryMutationAdmission, memory_id: Uuid, wing: &str, room: &str) -> Result<(), ()> {
        self.coordinator.lock().map_err(|_| ())?.reanchor(&admission.estate_handle, &memory_id.to_string(), Some(room), Some(wing), None).map_err(|_| ())
    }
    fn link(&self, admission: &V2MemoryMutationAdmission, request: &V2LinkMemoriesRequest) -> Result<Uuid, ()> {
        // The current authoritative tunnel frame has no confidence/evidence
        // columns. Refuse rather than claim a successful link that discarded
        // caller-provided assertion metadata.
        if request.confidence.is_some() || request.evidence.is_some() { return Err(()); }
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let estate = coordinator.estate_for(&admission.estate_handle).map_err(|_| ())?;
        let source = estate.drawer_by_id(&request.from_id.to_string()).map_err(|_| ())?.ok_or(())?;
        let target = estate.drawer_by_id(&request.to_id.to_string()).map_err(|_| ())?.ok_or(())?;
        let names = coordinator.resolve_drawer_node_names(&admission.estate_handle, &[source.parent_node_id.clone(), target.parent_node_id.clone()]);
        let (source_wing, source_room) = names.get(&source.parent_node_id).cloned().ok_or(())?;
        let (target_wing, target_room) = names.get(&target.parent_node_id).cloned().ok_or(())?;
        let mut frame = TunnelCaptureFrame::new(source_wing, source_room, target_wing, target_room, &request.relationship, &admission.caller_binding);
        frame.source_drawer_id = Some(request.from_id.to_string());
        frame.target_drawer_id = Some(request.to_id.to_string());
        frame.kind = relationship_kind(&request.relationship);
        let tunnel = estate.capture_tunnel(frame, admission.now_millis).map_err(|_| ())?;
        Uuid::parse_str(&tunnel.id).map_err(|_| ())
    }
    fn review(&self, admission: &V2MemoryMutationAdmission, tunnel_id: Uuid, decision: V2TunnelDecision, note: Option<&str>, reviewed_by: &str) -> Result<V2TunnelReviewReceipt, ()> {
        let coordinator = self.coordinator.lock().map_err(|_| ())?;
        let estate = coordinator.estate_for(&admission.estate_handle).map_err(|_| ())?;
        let canonical = tunnel_id.hyphenated().to_string();
        let stored = [canonical.clone(), canonical.to_uppercase()]
            .into_iter()
            .find_map(|candidate| estate.get_tunnel(&candidate).ok().flatten())
            .ok_or(())?;
        match decision {
            V2TunnelDecision::Endorse => {
                use genius_locus_kit::brain::conflict_projection_sweep::rejection_tier_of_label;
                use genius_locus_kit::brain::tiered_contradiction_search::ContradictionTier;
                let lens = match rejection_tier_of_label(&stored.label) {
                    Some(1) => ContradictionTier::TypedProven,
                    Some(2) => ContradictionTier::LexicalStructural,
                    _ => ContradictionTier::LexicalValue,
                };
                let (new_endorser, distinct_endorsers, contested) = coordinator
                    .endorse_tunnel(&admission.estate_handle, &stored.id, reviewed_by, lens, admission.now_millis)
                    .map_err(|_| ())?;
                Ok(V2TunnelReviewReceipt::Endorsed { new_endorser, distinct_endorsers, contested })
            }
            // A MODEL rejection is an objection, not a verdict.  It withdraws
            // only when no model endorsement stands; otherwise the tunnel stays
            // `.proposed` and is marked contested so the user sees a disputed
            // proposal rather than a silently buried one.  Routing this through
            // respond_to_tunnel would give a machine the permanence of a user
            // rejection, whose pairs are never re-proposed.
            V2TunnelDecision::Reject if reviewed_by != USER_REVIEWER => {
                use genius_locus_kit::brain::conflict_projection_sweep::rejection_tier_of_label;
                use genius_locus_kit::brain::tiered_contradiction_search::ContradictionTier;
                let lens = match rejection_tier_of_label(&stored.label) {
                    Some(1) => ContradictionTier::TypedProven,
                    Some(2) => ContradictionTier::LexicalStructural,
                    _ => ContradictionTier::LexicalValue,
                };
                let (withdrawn, contested) = coordinator
                    .object_to_tunnel(&admission.estate_handle, &stored.id, reviewed_by, lens, admission.now_millis)
                    .map_err(|_| ())?;
                Ok(V2TunnelReviewReceipt::Settled { withdrawn, contested })
            }
            // User verdicts only: `accept` is gated at decode, and a user
            // `reject` withdraws permanently.
            V2TunnelDecision::Accept | V2TunnelDecision::Reject => {
                estate.respond_to_tunnel(
                    &stored.id,
                    matches!(decision, V2TunnelDecision::Accept),
                    &admission.caller_binding,
                    note,
                    admission.now_millis,
                ).map_err(|_| ())?;
                Ok(V2TunnelReviewReceipt::Settled {
                    withdrawn: matches!(decision, V2TunnelDecision::Reject),
                    contested: false,
                })
            }
        }
    }
}

fn relationship_kind(value: &str) -> TunnelKind {
    match value {
        "precedes" | "blocks" => TunnelKind::Blocks,
        "contradicts" => TunnelKind::Contradicts,
        "supports" | "validates" => TunnelKind::Validates,
        "refines" | "elaborates" => TunnelKind::Elaborates,
        "exemplifies" | "covers" => TunnelKind::Covers,
        "extends" | "derives_from" => TunnelKind::DerivesFrom,
        "supersedes" => TunnelKind::Supersedes,
        "responds_to" => TunnelKind::RespondsTo,
        _ => TunnelKind::References,
    }
}
