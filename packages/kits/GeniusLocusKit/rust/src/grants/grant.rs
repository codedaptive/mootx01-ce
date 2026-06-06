// grant.rs — Rust port of Grant, GrantScope, GrantLifetime, CustodyMode,
// ReSharePermission, DriftRate, GrantOptions, GrantError, IssueGrantResult,
// StoredGrant.
//
// Mirror of Sources/GeniusLocusKit/Grants/Grant.swift. All types implement
// the signing payload exactly as the Swift side so a cross-platform audit
// trail can verify signatures and signing payloads without port-specific paths.
//
// Date representation: `issued_at` and `revoked_at` are stored as f64 seconds
// since the Apple reference date (2001-01-01 UTC) — matching the Swift side's
// `Date.timeIntervalSinceReferenceDate` so signing tokens are bit-identical.

use uuid::Uuid;

/// Granularity that a grant exposes, per §6 scope axis.
///
/// Mirror of Swift `GrantScope`. The `signing_token()` output must be
/// byte-identical to Swift's `var signingToken: String`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantScope {
    /// The entire estate (all wings, all rooms).
    WholeEstate,
    /// One named wing.
    Wing(String),
    /// One named room.
    Room(String),
    /// A lattice sub-tree rooted at `udc_code`.
    LatticeSubtree { udc_code: String },
    /// A single row identified by UUID.
    SingleRow(Uuid),
}

impl GrantScope {
    /// Deterministic token for the signing payload. Byte-identical to
    /// Swift `GrantScope.signingToken`.
    pub fn signing_token(&self) -> String {
        match self {
            GrantScope::WholeEstate => "estate".to_string(),
            GrantScope::Wing(name) => format!("wing:{name}"),
            GrantScope::Room(name) => format!("room:{name}"),
            GrantScope::LatticeSubtree { udc_code } => format!("lattice:{udc_code}"),
            GrantScope::SingleRow(id) => format!("row:{}", id.to_string().to_uppercase()),
        }
    }
}

/// How long a grant lives, per §7.
///
/// Mirror of Swift `GrantLifetime`.
#[derive(Debug, Clone, PartialEq)]
pub enum GrantLifetime {
    Permanent,
    Until(f64),       // seconds since Apple reference date (2001-01-01)
    DecayWindow { seconds: i64 },
}

impl GrantLifetime {
    /// Deterministic token for the signing payload. Byte-identical to
    /// Swift `GrantLifetime.signingToken`.
    pub fn signing_token(&self) -> String {
        match self {
            GrantLifetime::Permanent => "permanent".to_string(),
            GrantLifetime::Until(t) => format!("until:{t}"),
            GrantLifetime::DecayWindow { seconds } => format!("decay:{seconds}"),
        }
    }

    /// The expiry instant in Apple reference seconds, or `None` if permanent.
    pub fn expiry(&self, issued_at: f64) -> Option<f64> {
        match self {
            GrantLifetime::Permanent => None,
            GrantLifetime::Until(t) => Some(*t),
            GrantLifetime::DecayWindow { seconds } => Some(issued_at + *seconds as f64),
        }
    }
}

/// The four custody modes from Appendix B.
///
/// Mirror of Swift `CustodyMode`.
#[derive(Debug, Clone, PartialEq)]
pub enum CustodyMode {
    /// Mode 1: scope key held in vault, never leaves custody.
    Mediated,
    /// Mode 2: scope key derived once and handed to the recipient.
    HandedOver,
    /// Mode 3: decay-derived via Lagrange threshold over GF(p).
    /// Experimental (ENC-02); gated by `experimental_ip_clearance_confirmed`.
    DecayDerived {
        threshold: usize,
        total_shares: usize,
        drift_rate: DriftRate,
        experimental_ip_clearance_confirmed: bool,
    },
    /// Mode 4: physical SRAM decay. Not implemented in v1.0.
    PhysicalDecay {
        experimental_ip_clearance_confirmed: bool,
    },
}

impl CustodyMode {
    /// Discriminant token for the signing payload and the `custody_mode` column.
    /// Byte-identical to Swift `CustodyMode.signingToken`.
    pub fn signing_token(&self) -> &'static str {
        match self {
            CustodyMode::Mediated => "mediated",
            CustodyMode::HandedOver => "handedOver",
            CustodyMode::DecayDerived { .. } => "decayDerived",
            CustodyMode::PhysicalDecay { .. } => "physicalDecay",
        }
    }
}

/// Whether and how a grantee may re-share, per §6.
///
/// Mirror of Swift `ReSharePermission`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReSharePermission {
    None,
    WithAudit,
    Free,
}

impl ReSharePermission {
    pub fn signing_token(&self) -> &'static str {
        match self {
            ReSharePermission::None => "none",
            ReSharePermission::WithAudit => "withAudit",
            ReSharePermission::Free => "free",
        }
    }
}

/// Drift rate for custody mode 3's decay schedule.
///
/// Mirror of Swift `DriftRate`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftRate {
    Slow,
    Moderate,
    Fast,
}

/// Options for issuing a grant. Mirror of Swift `GrantOptions`.
#[derive(Debug, Clone)]
pub struct GrantOptions {
    pub grantee_estate_id: Uuid,
    pub scope: GrantScope,
    pub custody_mode: CustodyMode,
    pub lifetime: GrantLifetime,
    pub content_level: i64,
    pub re_share_permission: ReSharePermission,
}

/// A grant row. Mirror of Swift `Grant`.
///
/// `issued_at` is seconds since the Apple reference date (2001-01-01 00:00:00 UTC)
/// to match the signing-token format used by the Swift side.
#[derive(Debug, Clone, PartialEq)]
pub struct Grant {
    pub id: Uuid,
    pub grantee_estate_id: Uuid,
    pub scope: GrantScope,
    pub content_level: i64,
    pub lifetime: GrantLifetime,
    pub custody_mode: CustodyMode,
    pub re_share_permission: ReSharePermission,
    pub inference_remaining_budget: f64,
    pub issued_at: f64,     // Apple reference date seconds
    pub signature: Vec<u8>,
}

impl Grant {
    /// The canonical signing payload.
    ///
    /// Byte-identical to Swift `Grant.canonicalPayload(...)`: a pipe-delimited
    /// UTF-8 string of all grant fields except the signature itself. The
    /// `issued_at` token uses the same `timeIntervalSinceReferenceDate` float
    /// format as the Swift side so the byte stream is identical.
    pub fn canonical_payload(
        id: Uuid,
        grantee_estate_id: Uuid,
        scope: &GrantScope,
        content_level: i64,
        lifetime: &GrantLifetime,
        custody_mode: &CustodyMode,
        re_share_permission: &ReSharePermission,
        inference_remaining_budget: f64,
        issued_at: f64,
    ) -> Vec<u8> {
        let fields = [
            "grant-v1".to_string(),
            id.to_string().to_uppercase(),
            grantee_estate_id.to_string().to_uppercase(),
            scope.signing_token(),
            content_level.to_string(),
            lifetime.signing_token(),
            custody_mode.signing_token().to_string(),
            re_share_permission.signing_token().to_string(),
            inference_remaining_budget.to_string(),
            issued_at.to_string(),
        ];
        fields.join("|").into_bytes()
    }

    /// The signing payload for this grant (delegates to `canonical_payload`).
    pub fn signing_payload(&self) -> Vec<u8> {
        Self::canonical_payload(
            self.id,
            self.grantee_estate_id,
            &self.scope,
            self.content_level,
            &self.lifetime,
            &self.custody_mode,
            &self.re_share_permission,
            self.inference_remaining_budget,
            self.issued_at,
        )
    }
}

/// The result of issuing a grant. Mirror of Swift `IssueGrantResult`.
///
/// `scope_key` is `Some` for modes 2 and 3 (returned to the caller) and
/// `None` for mode 1 (held in the vault, never returned).
///
/// Debug is implemented manually to redact `scope_key` — the raw key bytes
/// must never appear in logs or debug output.
pub struct IssueGrantResult {
    pub grant: Grant,
    pub scope_key: Option<Vec<u8>>,
}

/// Manually implemented Debug that redacts the `scope_key` field.
///
/// The scope key bytes must never appear in logs, debug output, or panic
/// messages. `scope_key` is replaced by `"<REDACTED>"` regardless of
/// whether it is `Some` or `None`.
impl std::fmt::Debug for IssueGrantResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IssueGrantResult")
            .field("grant", &self.grant)
            .field("scope_key", &"<REDACTED>")
            .finish()
    }
}

/// A grant as held in the store, paired with its revocation instant.
/// Mirror of Swift `StoredGrant`.
pub struct StoredGrant {
    pub grant: Grant,
    /// `None` while active; seconds since Apple reference date when revoked.
    pub revoked_at: Option<f64>,
}

/// Errors raised by the grant surface. Mirror of Swift `GrantError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantError {
    GrantRevoked(Uuid),
    GrantExpired(Uuid),
    ExperimentalModeNotActivated,
    HardwareNotSupported,
    GrantNotFound(Uuid),
    ScopeKeyUnavailable(Uuid),
    KeyDecayed,
}
