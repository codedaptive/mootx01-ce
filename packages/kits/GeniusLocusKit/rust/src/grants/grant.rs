// grant.rs — Rust port of Grant, GrantScope, GrantLifetime, CustodyMode,
// ReSharePermission, DriftRate, GrantOptions, GrantError, IssueGrantResult,
// StoredGrant.
//
// Mirror of Sources/GeniusLocusKit/Grants/Grant.swift. All types implement
// the signing payload exactly as the Swift side so a cross-platform audit
// trail can verify signatures and signing payloads without port-specific paths.
//
// Date representation: on the Rust port, `issued_at`, `revoked_at`, and
// `decay_started_at` are f64 Unix epoch seconds (1970-01-01 UTC). The Swift
// port uses Apple reference date seconds (2001-01-01 UTC) via `Date`. Both
// ports persist dates as ISO-8601 TEXT, so the on-disk form is byte-identical
// for any given wall-clock instant. The raw f64 in signing tokens differs
// between ports by 978_307_200 (the Apple→Unix offset); cross-port
// signature verification must use the same epoch convention on both sides.

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
    Until(f64),       // Unix epoch seconds (1970-01-01) on the Rust port
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

    /// The expiry instant in Unix epoch seconds, or `None` if permanent.
    pub fn expiry(&self, issued_at: f64) -> Option<f64> {
        match self {
            GrantLifetime::Permanent => None,
            GrantLifetime::Until(t) => Some(*t),
            GrantLifetime::DecayWindow { seconds } => Some(issued_at + *seconds as f64),
        }
    }
}

/// The four custody modes (Appendix B). Modes 1 and 2 are production; mode 3
/// is experimental gated behind `experimental_ip_clearance_confirmed`; mode 4
/// is the time-aging decay policy.
///
/// Mode 4 — time-aging decay (`TimeAging`). The original Appendix B mode 4
/// modelled physical SRAM decay (the TARDIS technique, USENIX 2012): an estate
/// handed a grant whose effective capability attenuates over time the way data
/// retention in an unpowered SRAM cell decays. SRAM hardware is unavailable on
/// every beta surface, so the shipped policy is a deterministic SOFTWARE
/// time-aging model with the same semantics: the grant's effective content
/// level decays as a half-life function of elapsed time since `started_at`,
/// floored at `floor`. The attenuation is computed against an injected `now`
/// (no wall-clock read), so it is reproducible and bit-comparable with Swift.
///
/// The legacy `"physicalDecay"` discriminant token decodes INTO this variant.
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
    /// Mode 4: time-aging decay. The grant's effective content level
    /// attenuates as a half-life function of elapsed time, floored at the
    /// policy floor. Software analogue of the original SRAM physical-decay
    /// model (TARDIS); decay is deterministic in injected `now`.
    TimeAging(DecayPolicy),
}

impl CustodyMode {
    /// Signing token: identity, grantee, scope, and all custody parameters the
    /// signature must cover. For `TimeAging` the decay-policy fields ride in the
    /// token so a tampered half-life, start instant, or floor breaks signature
    /// verification. Byte-identical to Swift `CustodyMode.signingToken`.
    pub fn signing_token(&self) -> String {
        match self {
            CustodyMode::Mediated => "mediated".to_string(),
            CustodyMode::HandedOver => "handedOver".to_string(),
            CustodyMode::DecayDerived { .. } => "decayDerived".to_string(),
            CustodyMode::TimeAging(policy) => format!("timeAging|{}", policy.signing_token()),
        }
    }

    /// The bare `custody_mode` column discriminant — the persisted token without
    /// associated values. Mode 3's parameters (GRT-01 non-persistence) and mode
    /// 4's decay policy (the `decay_*` columns) live outside the token, so the
    /// column stores only the discriminant. Byte-identical to Swift
    /// `CustodyMode.columnToken`.
    pub fn column_token(&self) -> &'static str {
        match self {
            CustodyMode::Mediated => "mediated",
            CustodyMode::HandedOver => "handedOver",
            CustodyMode::DecayDerived { .. } => "decayDerived",
            CustodyMode::TimeAging(_) => "timeAging",
        }
    }
}

/// Parameters of the mode-4 time-aging custody policy. Mirror of Swift
/// `DecayPolicy`.
///
/// The effective content level at instant `now` (Unix epoch seconds, Rust port) is
/// `max(floor, round(base_level * 0.5^(elapsed / half_life_seconds)))`
/// where `elapsed = max(0, now - started_at)`. The half-life form mirrors the
/// matrix-calibration decay (math treatise §8). The fraction is computed in
/// `f64` and rounded to an integer so both ports produce identical discrete
/// values from identical fixtures. `floor` is the residual capability that
/// never ages away; a grant whose effective level reaches 0 (only when
/// `floor == 0`) is treated as fully decayed and refused on the recall path.
#[derive(Debug, Clone, PartialEq)]
pub struct DecayPolicy {
    /// Half-life of the capability in whole seconds. Every `half_life_seconds`
    /// of elapsed time halves the surviving (above-floor) content level. A
    /// non-positive value is clamped to 1 by `effective_level` so the formula
    /// never divides by zero.
    pub half_life_seconds: i64,
    /// The instant decay is measured from, in Unix epoch seconds (Rust port).
    /// Persisted explicitly so the decay clock is independent of `issued_at`;
    /// a legacy row with no decay fields documents `started_at = issued_at`.
    pub started_at: f64,
    /// The minimum content level the grant decays toward. `0` means the grant
    /// can decay to no access (and is refused once it reaches the floor); a
    /// positive value is a permanent residual capability.
    pub floor: i64,
}

impl DecayPolicy {
    /// Default half-life for a legacy mode-4 row with no persisted decay
    /// fields: 30 days in seconds. Matches the matrix-calibration decay default
    /// (`half_life_days = 30.0`) and Swift `DecayPolicy.defaultHalfLifeSeconds`.
    pub const DEFAULT_HALF_LIFE_SECONDS: i64 = 30 * 24 * 60 * 60;

    /// Deterministic token fragment for the signing payload. The instant is
    /// rendered as the same `f64` Unix-epoch-seconds form the Rust grant uses
    /// for `issued_at`. Note: the Swift port renders this in Apple-reference
    /// seconds; cross-port token identity requires both ports use the same epoch.
    pub fn signing_token(&self) -> String {
        format!(
            "halfLife:{}|start:{}|floor:{}",
            self.half_life_seconds, self.started_at, self.floor
        )
    }

    /// The effective content level of a `base_level` capability at `now`.
    ///
    /// Deterministic in `now`: `elapsed` is clamped to non-negative so a `now`
    /// before `started_at` yields the undecayed `base_level`, and a non-positive
    /// `half_life_seconds` is clamped to 1. The surviving level is
    /// `base_level * 0.5^(elapsed/half_life)`, rounded to the nearest integer
    /// (`f64::round`, matching Swift's `.toNearestOrAwayFromZero`), then floored.
    pub fn effective_level(&self, base_level: i64, now: f64) -> i64 {
        let elapsed = (now - self.started_at).max(0.0);
        let half_life = self.half_life_seconds.max(1) as f64;
        let surviving = base_level as f64 * 0.5_f64.powf(elapsed / half_life);
        let rounded = surviving.round() as i64;
        rounded.max(self.floor)
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
/// `issued_at` is Unix epoch seconds (1970-01-01 00:00:00 UTC) on the Rust
/// port. The Swift port uses Apple reference date seconds (2001-01-01). The
/// persisted form is ISO-8601 TEXT in both cases, so on-disk behaviour is
/// byte-identical. The raw f64 in signing tokens differs by the epoch offset.
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
    pub issued_at: f64,     // Unix epoch seconds (Rust port; Swift uses Apple-ref)
    pub signature: Vec<u8>,
}

impl Grant {
    /// The canonical signing payload.
    ///
    /// Pipe-delimited UTF-8 string of all grant fields except the signature.
    /// Mirrors Swift `Grant.canonicalPayload(...)`. NOTE: the `issued_at`
    /// field is Unix epoch seconds on the Rust port and Apple reference seconds
    /// on the Swift port — the raw numeric values differ by 978_307_200.
    /// Cross-port signature verification requires both ports to normalise to
    /// the same epoch before computing or verifying a payload.
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
#[derive(Debug)]
pub struct StoredGrant {
    pub grant: Grant,
    /// `None` while active; Unix epoch seconds when revoked (Rust port).
    pub revoked_at: Option<f64>,
}

/// Errors raised by the grant surface. Mirror of Swift `GrantError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantError {
    GrantRevoked(Uuid),
    GrantExpired(Uuid),
    ExperimentalModeNotActivated,
    GrantNotFound(Uuid),
    ScopeKeyUnavailable(Uuid),
    KeyDecayed,
}
