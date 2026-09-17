//! Typed v2 contradiction hunt and proposal-reference core.
//!
//! Hunt uses the direct read-only GeniusLocusKit tiered-search seam. Proposal
//! uses its explicit selected-candidate seam, which routes through LocusKit's
//! serializable fresh-read, validation, deduplication, and insertion boundary.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use serde::{ser::SerializeMap, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::jsonrpc::JsonValue;

use super::codec::{optional_integer, optional_uuid, required_string, strict_object, V2DecodeResult, V2InvalidArgument};

pub const CONTRADICTION_HUNT_TOOL: &str = "moot_hunt_contradictions";
pub const CONTRADICTION_PROPOSE_TOOL: &str = "moot_propose_contradictions";
pub const ANALYSIS_REFERENCE_TTL_MS: i64 = 10 * 60 * 1000;
pub const MAX_LIVE_ANALYSES_PER_CONTEXT: usize = 32;
pub const MAX_LIVE_ANALYSES_SERVER_WIDE: usize = 256;
pub const MAX_ANALYSIS_RETAINED_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_CANDIDATES_PER_ANALYSIS: usize = 1_000;
const RETAINED_ANALYSIS_ACCOUNTING_SLACK_BYTES: usize = 64;

/// The hunt boundary only accepts explicit estate selection. Search tuning is
/// server policy, so callers cannot use this operation to change its bounded
/// tiered-analysis profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ContradictionHuntRequest {
    pub estate_id: Option<Uuid>,
    pub limit: Option<usize>,
}

impl V2ContradictionHuntRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["limit", "estate_id"])?;
        let limit = optional_integer(object, "limit")?;
        if limit.is_some_and(|value| value < 1 || value as usize > MAX_CANDIDATES_PER_ANALYSIS) {
            return Err(V2InvalidArgument::new(
                "$.limit",
                format!("must be from 1 through {MAX_CANDIDATES_PER_ANALYSIS}"),
            ));
        }
        Ok(Self {
            estate_id: optional_uuid(object, "estate_id")?,
            limit: limit.map(|value| value as usize),
        })
    }
}

/// The proposal flow selects server-issued opaque candidate identifiers. They
/// deliberately are neither memory nor tunnel UUIDs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ContradictionProposalRequest {
    pub analysis_ref: String,
    pub candidate_ids: Vec<String>,
    pub estate_id: Option<Uuid>,
}

impl V2ContradictionProposalRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["analysis_ref", "candidate_ids", "estate_id"])?;
        let analysis_ref = nonempty_opaque(required_string(object, "analysis_ref")?, "$.analysis_ref")?;
        let candidates = object.get("candidate_ids").ok_or_else(|| {
            V2InvalidArgument::new("$.candidate_ids", "is required")
        })?;
        let array = candidates.as_array().ok_or_else(|| {
            V2InvalidArgument::new("$.candidate_ids", "must be an array of opaque candidate IDs")
        })?;
        if array.is_empty() {
            return Err(V2InvalidArgument::new("$.candidate_ids", "must not be empty"));
        }
        if array.len() > MAX_CANDIDATES_PER_ANALYSIS {
            return Err(V2InvalidArgument::new(
                "$.candidate_ids",
                format!("must contain at most {MAX_CANDIDATES_PER_ANALYSIS} candidate IDs"),
            ));
        }

        let mut candidate_ids = Vec::with_capacity(array.len());
        let mut unique = BTreeSet::new();
        for (index, value) in array.iter().enumerate() {
            let path = format!("$.candidate_ids[{index}]");
            let candidate_id = value
                .as_str()
                .ok_or_else(|| V2InvalidArgument::new(&path, "must be an opaque string"))?;
            let candidate_id = nonempty_opaque(candidate_id, &path)?;
            if !unique.insert(candidate_id.clone()) {
                return Err(V2InvalidArgument::new(&path, "must be unique"));
            }
            candidate_ids.push(candidate_id);
        }

        Ok(Self {
            analysis_ref,
            candidate_ids,
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

fn nonempty_opaque(value: &str, path: &str) -> V2DecodeResult<String> {
    if value.is_empty() {
        Err(V2InvalidArgument::new(path, "must not be empty"))
    } else {
        Ok(value.to_owned())
    }
}

/// Binding retained with an analysis result. The authorization context must
/// change when caller visibility or authorization policy changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ContradictionAnalysisBinding {
    pub estate_id: Uuid,
    pub authorization_context: String,
    pub analysis_revision: String,
}

/// Metadata supplied by the read-only tiered search adapter. It contains no
/// copied memory body: source and evidence digests must be computed by the
/// adapter from the exact strict reads that justified the finding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct V2ContradictionFinding {
    pub source_memory_id: String,
    pub target_memory_id: String,
    pub tier: u8,
    pub rule_or_cue_version: String,
    pub renewal_identity: String,
    pub source_digest: String,
    pub evidence_digest: String,
}

/// A publicly selectable finding. `candidate_id` is opaque and minted by the
/// server; source and target IDs remain metadata for the eventual atomic
/// revalidation boundary, never public selection identifiers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct V2ContradictionCandidate {
    pub candidate_id: String,
    pub source_memory_id: String,
    pub target_memory_id: String,
    pub tier: u8,
    pub rule_or_cue_version: String,
    pub renewal_identity: String,
    pub source_digest: String,
    pub evidence_digest: String,
}

impl V2ContradictionCandidate {
    fn from_finding(candidate_id: String, finding: V2ContradictionFinding) -> Self {
        Self {
            candidate_id,
            source_memory_id: finding.source_memory_id,
            target_memory_id: finding.target_memory_id,
            tier: finding.tier,
            rule_or_cue_version: finding.rule_or_cue_version,
            renewal_identity: finding.renewal_identity,
            source_digest: finding.source_digest,
            evidence_digest: finding.evidence_digest,
        }
    }
}

/// Successful hunt data. `expires_at_ms` is server controlled and derived
/// solely from `created_at_ms`; reads never extend it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct V2ContradictionHuntResult {
    pub analysis_ref: String,
    pub expires_at_ms: i64,
    pub candidates: Vec<V2ContradictionCandidate>,
}

/// Return-only evidence that lets a caller understand and select an opaque
/// contradiction candidate. This value is never stored in the retained
/// analysis cache; only candidate metadata and digests are retained there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ContradictionCandidateEvidence {
    pub candidate_id: String,
    pub reason: String,
    pub source_memory_id: String,
    pub source_excerpt: String,
    pub target_memory_id: String,
    pub target_excerpt: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredAnalysis {
    binding: V2ContradictionAnalysisBinding,
    created_at_ms: i64,
    expires_at_ms: i64,
    last_accessed_at_ms: i64,
    candidates: Vec<V2ContradictionCandidate>,
    retained_bytes: usize,
}

/// A server-local cache for hunt results. It holds only selection metadata and
/// digests, never memory bodies or snippets.
#[derive(Debug, Default)]
pub struct V2ContradictionAnalysisCache {
    analyses: BTreeMap<String, StoredAnalysis>,
    retained_bytes: usize,
}

impl V2ContradictionAnalysisCache {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn live_reference_count(&self) -> usize {
        self.analyses.len()
    }

    pub fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }

    /// Retain a read-only tiered-search result. The caller supplies opaque
    /// identities so tests and transports can use their own secure generator.
    pub fn store_hunt(
        &mut self,
        analysis_ref: String,
        candidate_ids: Vec<String>,
        binding: V2ContradictionAnalysisBinding,
        findings: Vec<V2ContradictionFinding>,
        now_ms: i64,
    ) -> Result<V2ContradictionHuntResult, V2ContradictionCacheError> {
        self.evict_expired(now_ms);
        if analysis_ref.is_empty() {
            return Err(V2ContradictionCacheError::InvalidAnalysisReference);
        }
        if self.analyses.contains_key(&analysis_ref) {
            return Err(V2ContradictionCacheError::DuplicateAnalysisReference);
        }
        if findings.len() > MAX_CANDIDATES_PER_ANALYSIS {
            return Err(V2ContradictionCacheError::CandidateLimitExceeded);
        }
        if candidate_ids.len() != findings.len() {
            return Err(V2ContradictionCacheError::CandidateIdentityCountMismatch);
        }
        let mut seen_ids = BTreeSet::new();
        let mut candidates = Vec::with_capacity(findings.len());
        for (candidate_id, finding) in candidate_ids.into_iter().zip(findings) {
            if candidate_id.is_empty() || !seen_ids.insert(candidate_id.clone()) {
                return Err(V2ContradictionCacheError::DuplicateCandidateIdentity);
            }
            if finding.tier == 0 || finding.tier > 3 {
                return Err(V2ContradictionCacheError::InvalidCandidateTier);
            }
            let source_id = Uuid::parse_str(&finding.source_memory_id).ok();
            let target_id = Uuid::parse_str(&finding.target_memory_id).ok();
            if !matches!(
                (source_id, target_id),
                (Some(source), Some(target))
                    if source.hyphenated().to_string() == finding.source_memory_id
                        && target.hyphenated().to_string() == finding.target_memory_id
                        && source.as_bytes() < target.as_bytes()
            ) {
                return Err(V2ContradictionCacheError::NonCanonicalCandidatePair);
            }
            if finding.rule_or_cue_version.is_empty()
                || finding.renewal_identity.is_empty()
                || finding.source_digest.is_empty()
                || finding.evidence_digest.is_empty()
            {
                return Err(V2ContradictionCacheError::IncompleteCandidateEvidence);
            }
            candidates.push(V2ContradictionCandidate::from_finding(candidate_id, finding));
        }

        let expires_at_ms = now_ms.saturating_add(ANALYSIS_REFERENCE_TTL_MS);
        let retained_bytes = serialized_len(
            &analysis_ref,
            &binding,
            now_ms,
            expires_at_ms,
            &candidates,
        )?;
        if retained_bytes > MAX_ANALYSIS_RETAINED_BYTES {
            return Err(V2ContradictionCacheError::RetainedStateLimitExceeded);
        }

        self.evict_to_context_capacity(&binding.authorization_context, now_ms);
        self.evict_to_server_capacity(now_ms);
        while self.retained_bytes.saturating_add(retained_bytes) > MAX_ANALYSIS_RETAINED_BYTES {
            if !self.evict_lru(None) {
                return Err(V2ContradictionCacheError::RetainedStateLimitExceeded);
            }
        }
        self.analyses.insert(
            analysis_ref.clone(),
            StoredAnalysis {
                binding,
                created_at_ms: now_ms,
                expires_at_ms,
                last_accessed_at_ms: now_ms,
                candidates: candidates.clone(),
                retained_bytes,
            },
        );
        self.retained_bytes += retained_bytes;
        Ok(V2ContradictionHuntResult {
            analysis_ref,
            expires_at_ms,
            candidates,
        })
    }

    /// Resolve explicit selections without re-running analysis. The returned
    /// metadata is the input to the future atomic LocusKit proposal operation.
    pub fn resolve_proposal(
        &mut self,
        request: &V2ContradictionProposalRequest,
        binding: &V2ContradictionAnalysisBinding,
        now_ms: i64,
    ) -> Result<Vec<V2ContradictionCandidate>, V2ContradictionProposalRefusal> {
        self.evict_expired(now_ms);
        let stored = self.analyses.get_mut(&request.analysis_ref).ok_or_else(|| {
            V2ContradictionProposalRefusal::expired()
        })?;
        if request.estate_id != Some(stored.binding.estate_id) && request.estate_id.is_some() {
            return Err(V2ContradictionProposalRefusal::estate_mismatch());
        }
        if stored.binding.authorization_context != binding.authorization_context {
            return Err(V2ContradictionProposalRefusal::context_mismatch());
        }
        if stored.binding.estate_id != binding.estate_id {
            return Err(V2ContradictionProposalRefusal::estate_mismatch());
        }
        if stored.binding.analysis_revision != binding.analysis_revision {
            return Err(V2ContradictionProposalRefusal::stale());
        }
        // LRU is accounting only. Expiry remains `created_at + TTL`.
        stored.last_accessed_at_ms = now_ms;
        let by_id: BTreeMap<&str, &V2ContradictionCandidate> = stored
            .candidates
            .iter()
            .map(|candidate| (candidate.candidate_id.as_str(), candidate))
            .collect();
        request
            .candidate_ids
            .iter()
            .map(|candidate_id| {
                by_id.get(candidate_id.as_str()).cloned().cloned().ok_or_else(|| {
                    V2ContradictionProposalRefusal::unknown_candidate(candidate_id)
                })
            })
            .collect()
    }

    /// Read the original absolute expiry for a live reference. This never
    /// extends retention and lets the renderer expose the same hunt contract
    /// for a selected proposal result.
    pub fn expires_at_ms(&mut self, analysis_ref: &str, now_ms: i64) -> Option<i64> {
        self.evict_expired(now_ms);
        self.analyses.get(analysis_ref).map(|stored| stored.expires_at_ms)
    }

    fn evict_expired(&mut self, now_ms: i64) {
        let expired: Vec<String> = self
            .analyses
            .iter()
            .filter_map(|(reference, stored)| (now_ms >= stored.expires_at_ms).then(|| reference.clone()))
            .collect();
        for reference in expired {
            self.remove(&reference);
        }
    }

    fn evict_to_context_capacity(&mut self, context: &str, now_ms: i64) {
        self.evict_expired(now_ms);
        while self
            .analyses
            .values()
            .filter(|stored| stored.binding.authorization_context == context)
            .count()
            >= MAX_LIVE_ANALYSES_PER_CONTEXT
        {
            if !self.evict_lru(Some(context)) {
                break;
            }
        }
    }

    fn evict_to_server_capacity(&mut self, now_ms: i64) {
        self.evict_expired(now_ms);
        while self.analyses.len() >= MAX_LIVE_ANALYSES_SERVER_WIDE {
            if !self.evict_lru(None) {
                break;
            }
        }
    }

    fn evict_lru(&mut self, context: Option<&str>) -> bool {
        let reference = self
            .analyses
            .iter()
            .filter(|(_, stored)| {
                context
                    .map(|context| stored.binding.authorization_context == context)
                    .unwrap_or(true)
            })
            .min_by(|(left_reference, left), (right_reference, right)| {
                left.last_accessed_at_ms
                    .cmp(&right.last_accessed_at_ms)
                    .then_with(|| left.created_at_ms.cmp(&right.created_at_ms))
                    .then_with(|| left_reference.cmp(right_reference))
            })
            .map(|(reference, _)| reference.clone());
        reference.map(|reference| self.remove(&reference)).is_some()
    }

    fn remove(&mut self, reference: &str) -> Option<StoredAnalysis> {
        let removed = self.analyses.remove(reference)?;
        self.retained_bytes = self.retained_bytes.saturating_sub(removed.retained_bytes);
        Some(removed)
    }
}

/// Read-only adapter for GeniusLocusKit's `TieredContradictionSearch` seam.
/// Its production implementation must calculate the source and evidence
/// digests from strict reads; it must not use the legacy hunter, which files
/// tunnels as part of its scan.
pub trait V2ReadOnlyContradictionHuntSource {
    fn hunt(
        &self,
        binding: &V2ContradictionAnalysisBinding,
    ) -> Result<Vec<V2ContradictionFinding>, String>;
}

/// Run the read-only source exactly once and retain its selection result. This
/// is intentionally separate from proposal resolution, so a proposal cannot
/// trigger a second analysis pass.
pub fn execute_hunt(
    source: &dyn V2ReadOnlyContradictionHuntSource,
    cache: &mut V2ContradictionAnalysisCache,
    analysis_ref: String,
    candidate_ids: Vec<String>,
    binding: V2ContradictionAnalysisBinding,
    now_ms: i64,
) -> Result<V2ContradictionHuntResult, V2ContradictionHuntError> {
    let findings = source.hunt(&binding).map_err(V2ContradictionHuntError::Source)?;
    cache
        .store_hunt(analysis_ref, candidate_ids, binding, findings, now_ms)
        .map_err(V2ContradictionHuntError::Cache)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2ContradictionHuntError {
    Source(String),
    Cache(V2ContradictionCacheError),
}

fn serialized_len(
    analysis_ref: &str,
    binding: &V2ContradictionAnalysisBinding,
    created_at_ms: i64,
    expires_at_ms: i64,
    candidates: &[V2ContradictionCandidate],
) -> Result<usize, V2ContradictionCacheError> {
    #[derive(Serialize)]
    struct RetainedBinding<'a> {
        estate_id: String,
        authorization_context: &'a str,
        analysis_revision: &'a str,
    }
    #[derive(Serialize)]
    struct Retained<'a> {
        analysis_ref: &'a str,
        binding: RetainedBinding<'a>,
        created_at_ms: i64,
        last_accessed_at_ms: i64,
        expires_at_ms: i64,
        candidates: &'a [V2ContradictionCandidate],
    }
    serde_json::to_vec(&Retained {
        analysis_ref,
        binding: RetainedBinding {
            estate_id: binding.estate_id.hyphenated().to_string(),
            authorization_context: &binding.authorization_context,
            analysis_revision: &binding.analysis_revision,
        },
        created_at_ms,
        last_accessed_at_ms: created_at_ms,
        expires_at_ms,
        candidates,
    })
    .map(|value| value.len())
    // Last-access time changes after retention. This fixed upper bound covers
    // both signed i64 encodings, keeping the 16 MiB limit conservative without
    // retaining a second serialized copy on every read.
    .and_then(|bytes| {
        bytes
            .checked_add(RETAINED_ANALYSIS_ACCOUNTING_SLACK_BYTES)
            .ok_or(serde_json::Error::io(std::io::Error::other("retained-state size overflow")))
    })
    .map_err(|_| V2ContradictionCacheError::RetainedStateEncodingFailed)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2ContradictionCacheError {
    InvalidAnalysisReference,
    DuplicateAnalysisReference,
    CandidateLimitExceeded,
    CandidateIdentityCountMismatch,
    DuplicateCandidateIdentity,
    InvalidCandidateTier,
    NonCanonicalCandidatePair,
    IncompleteCandidateEvidence,
    RetainedStateLimitExceeded,
    RetainedStateEncodingFailed,
}

/// An expected operational refusal from proposal reference resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ContradictionProposalRefusal {
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
    pub recovery: &'static str,
}

impl V2ContradictionProposalRefusal {
    fn expired() -> Self {
        Self {
            code: "proposal_expired",
            message: "the contradiction analysis reference expired or was evicted; run the hunt again".to_owned(),
            retryable: true,
            recovery: CONTRADICTION_HUNT_TOOL,
        }
    }

    fn stale() -> Self {
        Self {
            code: "proposal_stale",
            message: "the contradiction analysis is stale; run the hunt again".to_owned(),
            retryable: true,
            recovery: CONTRADICTION_HUNT_TOOL,
        }
    }

    fn context_mismatch() -> Self {
        Self {
            code: "proposal_context_mismatch",
            message: "the contradiction analysis belongs to a different authorization context".to_owned(),
            retryable: false,
            recovery: CONTRADICTION_HUNT_TOOL,
        }
    }

    fn estate_mismatch() -> Self {
        Self {
            code: "proposal_estate_mismatch",
            message: "estate_id does not match the contradiction analysis reference".to_owned(),
            retryable: false,
            recovery: CONTRADICTION_HUNT_TOOL,
        }
    }

    fn unknown_candidate(candidate_id: &str) -> Self {
        Self {
            code: "proposal_candidate_unavailable",
            message: format!("candidate ID {candidate_id:?} is not available in this analysis"),
            retryable: true,
            recovery: CONTRADICTION_HUNT_TOOL,
        }
    }
}

/// The three outcomes required from the future atomic filing operation. The
/// replay identity is the selected `(analysis_ref, candidate_id)` pair, while
/// the persisted edge identity is always the actual tunnel ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2ContradictionProposalStatus {
    Created { tunnel_id: String, lifecycle: String },
    Existing { tunnel_id: String, lifecycle: String },
    Settled,
}

impl Serialize for V2ContradictionProposalStatus {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(match self {
            Self::Settled => 1,
            Self::Created { .. } | Self::Existing { .. } => 3,
        }))?;
        match self {
            Self::Created { tunnel_id, lifecycle } => {
                map.serialize_entry("status", "created")?;
                map.serialize_entry("tunnel_id", tunnel_id)?;
                map.serialize_entry("lifecycle", lifecycle)?;
            }
            Self::Existing { tunnel_id, lifecycle } => {
                map.serialize_entry("status", "existing")?;
                map.serialize_entry("tunnel_id", tunnel_id)?;
                map.serialize_entry("lifecycle", lifecycle)?;
            }
            Self::Settled => {
                map.serialize_entry("status", "settled")?;
            }
        }
        map.end()
    }
}

/// Run only GeniusLocusKit's read-only tiered search and retain its exact
/// lower-row evidence digests. No legacy hunter or text renderer participates.
pub fn hunt_from_coordinator(
    coordinator: &Arc<Mutex<genius_locus_kit::coordinator::EstateCoordinator>>,
    handle: &genius_locus_kit::handle::EstateHandle,
    binding: &V2ContradictionAnalysisBinding,
    limit: usize,
    now_ms: i64,
) -> Result<Vec<V2ContradictionFinding>, String> {
    use genius_locus_kit::brain::tiered_contradiction_search::ContradictionTier;
    if Uuid::from_bytes(handle.estate_uuid) != binding.estate_id {
        return Err("the selected estate is unavailable".to_owned());
    }
    let coordinator = coordinator.lock().map_err(|_| "estate coordinator lock poisoned".to_owned())?;
    // Discovery must not silently shrink to the legacy 50 most recent memories.
    let report = coordinator.tiered_contradiction_search(handle, None, limit, "minilm-v6", 1_000, now_ms)
        .map_err(|error| format!("tiered contradiction search failed: {error:?}"))?;
    let drawers = coordinator.all_drawers(handle)
        .map_err(|error| format!("contradiction drawer inventory failed: {error:?}"))?;
    let by_id: BTreeMap<&str, &locus_kit::drawer::Drawer> = drawers.iter().map(|drawer| (drawer.id.as_str(), drawer)).collect();
    report.tier1.into_iter().chain(report.tier2).chain(report.tier3).take(limit).map(|finding| {
        let source = by_id.get(finding.drawer_a.as_str()).ok_or_else(|| "selected contradiction evidence is unavailable".to_owned())?;
        let target = by_id.get(finding.drawer_b.as_str()).ok_or_else(|| "selected contradiction evidence is unavailable".to_owned())?;
        if source.tombstoned_at.is_some() || target.tombstoned_at.is_some() {
            return Err("selected contradiction evidence is unavailable".to_owned());
        }
        let tier = finding.tier.raw_value();
        let renewal_identity = match finding.tier {
            ContradictionTier::TypedProven => format!("dcp: {}@{}", finding.rule_id.as_deref().ok_or_else(|| "typed contradiction rule missing".to_owned())?, finding.rule_version.as_deref().ok_or_else(|| "typed contradiction rule version missing".to_owned())?),
            ContradictionTier::LexicalStructural => format!("tier2:{}@{}", finding.cue_kind.as_deref().ok_or_else(|| "lexical contradiction cue missing".to_owned())?, genius_locus_kit::brain::conflict_projection_sweep::CONFLICT_CUE_VERSION),
            ContradictionTier::LexicalValue => format!("tier3:{}@{}", finding.cue_kind.as_deref().ok_or_else(|| "lexical contradiction cue missing".to_owned())?, genius_locus_kit::brain::conflict_projection_sweep::CONFLICT_CUE_VERSION),
        };
        let (source_digest, evidence_digest) = locus_kit::drawer_store::conflict_proposal_digests(source, target, tier, &renewal_identity);
        Ok(V2ContradictionFinding {
            source_memory_id: source.id.clone(), target_memory_id: target.id.clone(), tier,
            rule_or_cue_version: renewal_identity.clone(), renewal_identity, source_digest, evidence_digest,
        })
    }).collect()
}

pub fn execute_coordinator_hunt(
    coordinator: &Arc<Mutex<genius_locus_kit::coordinator::EstateCoordinator>>,
    handle: &genius_locus_kit::handle::EstateHandle,
    cache: &mut V2ContradictionAnalysisCache,
    binding: V2ContradictionAnalysisBinding,
    limit: usize,
    now_ms: i64,
) -> Result<V2ContradictionHuntResult, String> {
    let findings = hunt_from_coordinator(coordinator, handle, &binding, limit, now_ms)?;
    let analysis_ref = format!("analysis_{}", Uuid::new_v4().hyphenated());
    let candidate_ids = findings.iter().map(|_| format!("candidate_{}", Uuid::new_v4().hyphenated())).collect();
    cache.store_hunt(analysis_ref, candidate_ids, binding, findings, now_ms).map_err(|error| format!("analysis retention failed: {error:?}"))
}

/// Re-read only the selected endpoints through the default current,
/// trustworthy, elevated-sensitivity frame before rendering them. Bodies are
/// capped for this response and are never copied into the retained analysis.
pub fn coordinator_candidate_evidence(
    coordinator: &Arc<Mutex<genius_locus_kit::coordinator::EstateCoordinator>>,
    handle: &genius_locus_kit::handle::EstateHandle,
    candidates: &[V2ContradictionCandidate],
) -> Result<Vec<V2ContradictionCandidateEvidence>, String> {
    use locus_kit::{
        adjectives::AdjectiveSensitivity,
        filter::{Filter, HydrationLevel, RecallFrame},
    };

    if candidates.is_empty() {
        return Ok(Vec::new());
    }
    let mut ids = Vec::with_capacity(candidates.len() * 2);
    for candidate in candidates {
        for raw in [&candidate.source_memory_id, &candidate.target_memory_id] {
            let id = Uuid::parse_str(raw)
                .map_err(|_| "selected contradiction evidence is unavailable".to_owned())?
                .hyphenated()
                .to_string();
            ids.push(id.clone());
            ids.push(id.to_uppercase());
        }
    }
    ids.sort();
    ids.dedup();
    let mut frame = RecallFrame::new(vec![
        Filter::CurrentlyBelieve,
        Filter::Trustworthy,
        Filter::SensitivityAtMost(AdjectiveSensitivity::Elevated),
    ]);
    frame.hydration_level = HydrationLevel::Full;
    let coordinator = coordinator.lock().map_err(|_| "estate coordinator lock poisoned".to_owned())?;
    let drawers = coordinator
        .get_drawers_matching_frame(handle, &ids, &frame)
        .map_err(|error| format!("contradiction evidence hydration failed: {error:?}"))?;
    candidate_evidence_from_drawers(candidates, &drawers)
}

pub fn candidate_evidence_from_drawers(
    candidates: &[V2ContradictionCandidate],
    drawers: &[locus_kit::drawer::Drawer],
) -> Result<Vec<V2ContradictionCandidateEvidence>, String> {
    let mut by_id: BTreeMap<String, &locus_kit::drawer::Drawer> = BTreeMap::new();
    for drawer in drawers {
        let Ok(id) = Uuid::parse_str(&drawer.id) else { continue };
        if by_id.insert(id.hyphenated().to_string(), drawer).is_some() {
            return Err("selected contradiction evidence is unavailable".to_owned());
        }
    }
    candidates
        .iter()
        .map(|candidate| {
            let source_id = Uuid::parse_str(&candidate.source_memory_id)
                .map_err(|_| "selected contradiction evidence is unavailable".to_owned())?
                .hyphenated()
                .to_string();
            let target_id = Uuid::parse_str(&candidate.target_memory_id)
                .map_err(|_| "selected contradiction evidence is unavailable".to_owned())?
                .hyphenated()
                .to_string();
            let source = by_id
                .get(&source_id)
                .ok_or_else(|| "selected contradiction evidence is unavailable".to_owned())?;
            let target = by_id
                .get(&target_id)
                .ok_or_else(|| "selected contradiction evidence is unavailable".to_owned())?;
            let provenance_allowed = |drawer: &locus_kit::drawer::Drawer| {
                matches!((drawer.provenance >> 30) & 0x3f, 0 | 16)
            };
            if !provenance_allowed(source) || !provenance_allowed(target) {
                return Err("selected contradiction evidence is unavailable".to_owned());
            }
            let (source_digest, evidence_digest) = locus_kit::drawer_store::conflict_proposal_digests(
                source,
                target,
                candidate.tier,
                &candidate.renewal_identity,
            );
            if source_digest != candidate.source_digest || evidence_digest != candidate.evidence_digest {
                return Err("selected contradiction evidence is unavailable".to_owned());
            }
            Ok(V2ContradictionCandidateEvidence {
                candidate_id: candidate.candidate_id.clone(),
                reason: candidate.rule_or_cue_version.clone(),
                source_memory_id: source_id,
                source_excerpt: source.content.chars().take(512).collect(),
                target_memory_id: target_id,
                target_excerpt: target.content.chars().take(512).collect(),
            })
        })
        .collect()
}

pub fn execute_coordinator_proposal(
    coordinator: &Arc<Mutex<genius_locus_kit::coordinator::EstateCoordinator>>,
    handle: &genius_locus_kit::handle::EstateHandle,
    cache: &mut V2ContradictionAnalysisCache,
    request: &V2ContradictionProposalRequest,
    binding: &V2ContradictionAnalysisBinding,
    now_ms: i64,
) -> Result<Vec<V2ContradictionProposalStatus>, V2ContradictionProposalRefusal> {
    let candidates = cache.resolve_proposal(request, binding, now_ms)?;
    let selected = candidates.iter().map(|candidate| {
        let mut digest = Sha256::new();
        digest.update(request.analysis_ref.as_bytes());
        digest.update([0]);
        digest.update(candidate.candidate_id.as_bytes());
        let replay_identity = format!("aria-v2:{}", digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect::<String>());
        // The hunt's canonical pair spelling (both ids lowercased, sorted,
        // joined by a double bar); the retained candidate already holds the
        // pair in canonical order (resolve_proposal refuses any other).
        let mut pair = [candidate.source_memory_id.to_lowercase(), candidate.target_memory_id.to_lowercase()];
        pair.sort();
        genius_locus_kit::coordinator::SelectedConflictProposal {
            source_drawer_id: candidate.source_memory_id.clone(), target_drawer_id: candidate.target_memory_id.clone(),
            pair_key: format!("{}||{}", pair[0], pair[1]),
            tier: candidate.tier, renewal_identity: candidate.renewal_identity.clone(), label: candidate.renewal_identity.clone(),
            replay_identity, source_digest: candidate.source_digest.clone(), evidence_digest: candidate.evidence_digest.clone(),
        }
    }).collect::<Vec<_>>();
    let outcomes = coordinator.lock().map_err(|_| V2ContradictionProposalRefusal::stale())?
        .file_selected_conflict_proposals(handle, &selected, now_ms)
        .map_err(|_| V2ContradictionProposalRefusal::stale())?;
    // A stale outcome halts with the top-level `proposal_stale` refusal rather
    // than reporting partial results, as Swift's AriaV2Contradictions.propose
    // does at the first stale candidate.
    let mut statuses = Vec::with_capacity(outcomes.len());
    for outcome in outcomes {
        statuses.push(match outcome {
            locus_kit::drawer_store::AtomicConflictProposalOutcome::Created { tunnel_id, lifecycle } => V2ContradictionProposalStatus::Created { tunnel_id, lifecycle },
            locus_kit::drawer_store::AtomicConflictProposalOutcome::Existing { tunnel_id, lifecycle } => V2ContradictionProposalStatus::Existing { tunnel_id, lifecycle },
            locus_kit::drawer_store::AtomicConflictProposalOutcome::Settled => V2ContradictionProposalStatus::Settled,
            locus_kit::drawer_store::AtomicConflictProposalOutcome::Stale => return Err(V2ContradictionProposalRefusal::stale()),
        });
    }
    Ok(statuses)
}
