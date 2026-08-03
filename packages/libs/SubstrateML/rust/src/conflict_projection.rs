//! Deterministic Contradiction Projection v0.1 — the substrate core
//! (DCP M1; contract: docs_internal/analysis/DCP_M0_CONTRACT.md; spec
//! E7EE4031). Pure value types and pure functions: no database, clock,
//! network, locale, or random dependency.
//!
//! Twin of Swift `ConflictProjection.swift`. Parity is behavioral —
//! the shared golden corpus requires byte-identical canonical values,
//! outcome classes, reason codes, and stable identities.
//!
//! The lexical `conflict_cue` module is UNCHANGED: its output is
//! candidate evidence for review, never proof.

use std::collections::BTreeMap;

use substrate_kernel::sha256;

// ---------------------------------------------------------------------------
// Typed values
// ---------------------------------------------------------------------------

/// A typed canonical value (M0 §3). `canonical_bytes` is the identity
/// serialization — byte-for-byte shared with Swift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypedConflictValue {
    Boolean(bool),
    Integer(i64),
    /// Exact decimal: integer mantissa + decimal scale. No floats.
    Decimal { mantissa: i64, scale: u8 },
    /// Whole seconds.
    Duration { seconds: i64 },
    Date { year: i32, month: u8, day: u8 },
    Instant(i64),
    Version(Vec<u32>),
    /// (rule_id, canonical token) — membership checked at normalize.
    EnumToken { rule_id: String, token: String },
    EntityId(String),
    /// Equality only; similarity never proves anything.
    NormalizedString(String),
}

impl TypedConflictValue {
    /// The M0 §3 canonical identity bytes.
    pub fn canonical_bytes(&self) -> String {
        match self {
            Self::Boolean(b) => format!("b:{}", if *b { "true" } else { "false" }),
            Self::Integer(i) => format!("i:{i}"),
            Self::Decimal { mantissa, scale } => {
                let mut m = *mantissa;
                let mut s = *scale as i64;
                while s > 0 && m % 10 == 0 {
                    m /= 10;
                    s -= 1;
                }
                if s == 0 {
                    return format!("d:{m}");
                }
                let negative = m < 0;
                let digits = m.unsigned_abs().to_string();
                let width = (s + 1).max(digits.len() as i64) as usize;
                let padded = format!("{digits:0>width$}");
                let cut = padded.len() - s as usize;
                format!(
                    "d:{}{}.{}",
                    if negative { "-" } else { "" },
                    &padded[..cut],
                    &padded[cut..]
                )
            }
            Self::Duration { seconds } => format!("dur:{seconds}"),
            Self::Date { year, month, day } => format!("dt:{year:04}-{month:02}-{day:02}"),
            Self::Instant(t) => format!("ts:{t}"),
            Self::Version(comps) => format!(
                "v:{}",
                comps.iter().map(|c| c.to_string()).collect::<Vec<_>>().join(".")
            ),
            Self::EnumToken { rule_id, token } => format!("e:{rule_id}#{token}"),
            Self::EntityId(id) => format!("id:{id}"),
            Self::NormalizedString(s) => format!("s:{s}"),
        }
    }

    /// Exact equivalence — canonical-byte equality.
    pub fn is_equivalent(&self, other: &Self) -> bool {
        self.canonical_bytes() == other.canonical_bytes()
    }
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Validity basis (M0 §5). `Unknown` is distinct from all-time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemporalBasis {
    Point { epoch_seconds: i64 },
    Interval { from: i64, to: i64 },
    Unknown,
}

impl TemporalBasis {
    pub fn canonical_bytes(&self) -> String {
        match self {
            Self::Point { epoch_seconds } => format!("t:pt:{epoch_seconds}"),
            Self::Interval { from, to } => format!("t:iv:{from}:{to}"),
            Self::Unknown => "t:unknown".to_string(),
        }
    }

    /// Closed-interval overlap; `None` when either side is unknown.
    pub fn overlaps(&self, other: &Self) -> Option<bool> {
        let range = |b: &Self| match b {
            Self::Point { epoch_seconds } => Some((*epoch_seconds, *epoch_seconds)),
            Self::Interval { from, to } => Some((*from, *to)),
            Self::Unknown => None,
        };
        let a = range(self)?;
        let b = range(other)?;
        Some(a.0 <= b.1 && b.0 <= a.1)
    }

    pub fn is_malformed(&self) -> bool {
        matches!(self, Self::Interval { from, to } if from > to)
    }
}

// ---------------------------------------------------------------------------
// Signature
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictClaimStatus {
    Asserted,
    Proposed,
    Withdrawn,
    Rejected,
}

/// A source-grounded normalized claim (M0 §3, spec §6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictSignature {
    pub key: String,
    pub dimension: String,
    pub value: TypedConflictValue,
    pub source_drawer_id: String,
    /// Transaction time (KGFact.filed_at), epoch seconds.
    pub transaction_time: i64,
    pub validity: TemporalBasis,
    pub status: ConflictClaimStatus,
    pub rule_id: String,
    pub rule_version: u32,
    pub extractor_id: Option<String>,
    pub evidence_locator: Option<String>,
}

impl ConflictSignature {
    /// M0 §3 identity input, before hashing. Domain-separated.
    pub fn stable_id_input(&self) -> String {
        format!(
            "dcp1|{}@{}|{}|{}|{}|{}|{}",
            self.rule_id,
            self.rule_version,
            self.key,
            self.dimension,
            self.value.canonical_bytes(),
            self.source_drawer_id,
            self.validity.canonical_bytes()
        )
    }

    /// SHA-256 of the identity input, lowercase hex.
    pub fn stable_id(&self) -> String {
        sha256_hex(&self.stable_id_input())
    }
}

pub fn sha256_hex(input: &str) -> String {
    sha256::hash(input.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Pair-order-invariant result identity (M0 §3).
pub fn pair_id(a: &str, b: &str) -> String {
    let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
    sha256_hex(&format!("dcp1|pair|{lo}+{hi}"))
}

// ---------------------------------------------------------------------------
// Reason codes
// ---------------------------------------------------------------------------

/// Stable API spellings (M0 §4 — exactly the spec §11 list).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictReason {
    SameCoordinate,
    ValueEquivalent,
    ValuesExclusive,
    CardinalityMulti,
    ScopeMismatch,
    ScopeUnknown,
    ValidityOverlap,
    ValidityDisjoint,
    ValidityUnknown,
    AcceptedSupersession,
    SourceBelowThreshold,
    ParseAmbiguous,
    RuleUnknown,
    BucketTruncated,
}

impl ConflictReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::SameCoordinate => "same_coordinate",
            Self::ValueEquivalent => "value_equivalent",
            Self::ValuesExclusive => "values_exclusive",
            Self::CardinalityMulti => "cardinality_multi",
            Self::ScopeMismatch => "scope_mismatch",
            Self::ScopeUnknown => "scope_unknown",
            Self::ValidityOverlap => "validity_overlap",
            Self::ValidityDisjoint => "validity_disjoint",
            Self::ValidityUnknown => "validity_unknown",
            Self::AcceptedSupersession => "accepted_supersession",
            Self::SourceBelowThreshold => "source_below_threshold",
            Self::ParseAmbiguous => "parse_ambiguous",
            Self::RuleUnknown => "rule_unknown",
            Self::BucketTruncated => "bucket_truncated",
        }
    }
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictCardinality {
    Single,
    Set,
    Bag,
    Unknown,
}

type Normalizer = fn(&str) -> Option<TypedConflictValue>;

/// A versioned dimension rule (spec §8). v0.1 rules are code, not data.
#[derive(Clone)]
pub struct ConflictRule {
    pub rule_id: &'static str,
    pub version: u32,
    pub dimension: &'static str,
    pub cardinality: ConflictCardinality,
    pub normalize: Normalizer,
}

/// Total registry: a registered rule or None meaning UnknownRule.
/// UnknownRule can never prove a contradiction.
pub struct ConflictRuleRegistry {
    by_dimension: BTreeMap<String, ConflictRule>,
}

pub const UNKNOWN_RULE_ID: &str = "dim.unknown";

impl ConflictRuleRegistry {
    pub fn new(rules: Vec<ConflictRule>) -> Self {
        let mut map = BTreeMap::new();
        for rule in rules {
            map.insert(normalize::dimension_key(rule.dimension), rule);
        }
        Self { by_dimension: map }
    }

    pub fn rule_for_dimension(&self, dimension: &str) -> Option<&ConflictRule> {
        self.by_dimension.get(&normalize::dimension_key(dimension))
    }

    /// The v0.1 registry (M0 §2). Twin of Swift
    /// `ConflictRuleRegistry.v01`.
    pub fn v01() -> Self {
        Self::new(vec![
            ConflictRule {
                rule_id: "dim.person.employer",
                version: 1,
                dimension: "employer",
                cardinality: ConflictCardinality::Single,
                normalize: normalize::employer,
            },
            ConflictRule {
                rule_id: "dim.person.city",
                version: 1,
                dimension: "city",
                cardinality: ConflictCardinality::Single,
                normalize: normalize::city,
            },
            ConflictRule {
                rule_id: "dim.person.role",
                version: 1,
                dimension: "role",
                cardinality: ConflictCardinality::Single,
                normalize: normalize::role,
            },
            ConflictRule {
                rule_id: "dim.person.primary_language",
                version: 1,
                dimension: "primary language",
                cardinality: ConflictCardinality::Single,
                normalize: normalize::primary_language,
            },
            ConflictRule {
                rule_id: "dim.decision.launch_date",
                version: 1,
                dimension: "decision:launch_date",
                cardinality: ConflictCardinality::Single,
                normalize: normalize::launch_date,
            },
            ConflictRule {
                rule_id: "dim.decision.budget_ceiling",
                version: 1,
                dimension: "decision:budget_ceiling",
                cardinality: ConflictCardinality::Single,
                normalize: normalize::budget_ceiling,
            },
        ])
    }
}

/// Deterministic normalization helpers (M0 §3). Twin of Swift
/// `ConflictNormalize`. NFC normalization: identity fields here are
/// ASCII by construction (registry tokens + generated corpora); full
/// NFC arrives with a unicode-normalization decision if a rule ever
/// needs it — until then both ports collapse whitespace and lowercase
/// identically over ASCII, and the golden corpus pins the behavior.
pub mod normalize {
    use super::TypedConflictValue;

    pub fn collapse(raw: &str) -> String {
        raw.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    pub fn enum_token(raw: &str) -> String {
        collapse(raw).to_lowercase()
    }

    pub fn dimension_key(raw: &str) -> String {
        collapse(raw).to_lowercase()
    }

    fn closed_enum(rule_id: &'static str, members: &[&str], raw: &str) -> Option<TypedConflictValue> {
        let token = enum_token(raw);
        if members.iter().any(|m| enum_token(m) == token) {
            Some(TypedConflictValue::EnumToken {
                rule_id: rule_id.to_string(),
                token,
            })
        } else {
            None
        }
    }

    pub fn employer(raw: &str) -> Option<TypedConflictValue> {
        closed_enum(
            "dim.person.employer",
            &["Acme Robotics", "Northwind Analytics", "Beta Corp", "Vireo Systems", "Halcyon Labs"],
            raw,
        )
    }

    pub fn city(raw: &str) -> Option<TypedConflictValue> {
        closed_enum(
            "dim.person.city",
            &["Lisbon", "Toronto", "Osaka", "Nairobi", "Reykjavik"],
            raw,
        )
    }

    pub fn role(raw: &str) -> Option<TypedConflictValue> {
        closed_enum(
            "dim.person.role",
            &["staff engineer", "engineering manager", "principal architect",
              "director of platform", "technical lead"],
            raw,
        )
    }

    pub fn primary_language(raw: &str) -> Option<TypedConflictValue> {
        closed_enum(
            "dim.person.primary_language",
            &["Swift", "Rust", "Elixir", "OCaml", "Zig"],
            raw,
        )
    }

    /// Strict ISO `YYYY-MM-DD` only.
    pub fn launch_date(raw: &str) -> Option<TypedConflictValue> {
        let s = collapse(raw);
        let parts: Vec<&str> = s.split('-').collect();
        if parts.len() != 3 || parts[0].len() != 4 || parts[1].len() != 2 || parts[2].len() != 2 {
            return None;
        }
        let y: i32 = parts[0].parse().ok()?;
        let m: u8 = parts[1].parse().ok()?;
        let d: u8 = parts[2].parse().ok()?;
        if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
            return None;
        }
        Some(TypedConflictValue::Date { year: y, month: m, day: d })
    }

    /// USD decimal with exact `k`/`m` suffix scaling. Twin of Swift
    /// `ConflictNormalize.usdDecimal`.
    pub fn budget_ceiling(raw: &str) -> Option<TypedConflictValue> {
        let mut s = collapse(raw).to_lowercase();
        s = s.replace("usd", "").replace('$', "").replace(',', "");
        let mut s = s.trim().to_string();
        let mut multiplier: i64 = 1;
        if let Some(stripped) = s.strip_suffix('k') {
            multiplier = 1_000;
            s = stripped.trim().to_string();
        } else if let Some(stripped) = s.strip_suffix('m') {
            multiplier = 1_000_000;
            s = stripped.trim().to_string();
        }
        if s.is_empty() {
            return None;
        }
        let negative = s.starts_with('-');
        if negative {
            s = s[1..].to_string();
        }
        let pieces: Vec<&str> = s.split('.').collect();
        if pieces.len() > 2 || pieces.iter().any(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_digit())) {
            return None;
        }
        let int_part: i64 = pieces[0].parse().ok()?;
        let mut mantissa = int_part;
        let mut scale: u8 = 0;
        if pieces.len() == 2 {
            let frac = pieces[1];
            if frac.len() > 6 {
                return None;
            }
            let frac_val: i64 = frac.parse().ok()?;
            scale = frac.len() as u8;
            for _ in 0..scale {
                mantissa = mantissa.checked_mul(10)?;
            }
            mantissa = mantissa.checked_add(frac_val)?;
        }
        mantissa = mantissa.checked_mul(multiplier)?;
        if negative {
            mantissa = -mantissa;
        }
        Some(TypedConflictValue::Decimal { mantissa, scale })
    }

    /// Exact duration: `<n>h`/`<n>min`/`<n>s` → seconds.
    pub fn duration(raw: &str) -> Option<TypedConflictValue> {
        let s = collapse(raw).to_lowercase().replace(' ', "");
        let value = |suffix: &str, mult: i64| -> Option<TypedConflictValue> {
            let n: i64 = s.strip_suffix(suffix)?.parse().ok()?;
            Some(TypedConflictValue::Duration { seconds: n * mult })
        };
        value("min", 60).or_else(|| value("h", 3600)).or_else(|| value("s", 1))
    }
}

// ---------------------------------------------------------------------------
// Outcomes + evaluator
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictOutcomeKind {
    InvalidInput,
    Irrelevant,
    Agreement,
    CompatiblePlurality,
    HistoricalSuccession,
    ProvenContradiction,
    CandidateReview,
}

impl ConflictOutcomeKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::InvalidInput => "invalid_input",
            Self::Irrelevant => "irrelevant",
            Self::Agreement => "agreement",
            Self::CompatiblePlurality => "compatible_plurality",
            Self::HistoricalSuccession => "historical_succession",
            Self::ProvenContradiction => "proven_contradiction",
            Self::CandidateReview => "candidate_review",
        }
    }
}

/// The evaluation record (spec §11). No generated prose — explanations
/// are built from reason codes by callers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictOutcome {
    pub kind: ConflictOutcomeKind,
    pub result_id: String,
    pub rule_id: String,
    pub rule_version: u32,
    pub key: String,
    pub dimension: String,
    pub source_drawer_ids: Vec<String>,
    pub value_digests: Vec<String>,
    /// Canonical temporal-basis bytes of the two claims, sorted (the
    /// M0 §7 per-proven block's "temporal basis" field).
    pub temporal_bases: Vec<String>,
    pub reasons: Vec<ConflictReason>,
}

impl ConflictOutcome {
    /// Coordinate digest for redacted rendering (M0 §8): the restricted
    /// line names the coordinate only through this digest — never the
    /// key, dimension, or value digests (enum domains are small, so
    /// value digests are guessable).
    pub fn coordinate_digest(&self) -> String {
        sha256_hex(&format!("dcp1|coord|{}|{}", self.key, self.dimension))
    }
}

/// Pairwise pure evaluation (spec §5 predicates, M0 §6 precedence).
/// Accepted-supersession context is a caller-supplied boolean (M3
/// resolves tunnels; this stays pure). Twin of Swift
/// `ConflictEvaluator.evaluate`.
pub fn evaluate(
    a: &ConflictSignature,
    b: &ConflictSignature,
    registry: &ConflictRuleRegistry,
    accepted_supersession: bool,
) -> ConflictOutcome {
    let outcome = |kind: ConflictOutcomeKind, reasons: Vec<ConflictReason>| {
        let mut source_ids = vec![a.source_drawer_id.clone(), b.source_drawer_id.clone()];
        source_ids.sort();
        let mut digests = vec![
            sha256_hex(&format!("dcp1|value|{}", a.value.canonical_bytes())),
            sha256_hex(&format!("dcp1|value|{}", b.value.canonical_bytes())),
        ];
        digests.sort();
        ConflictOutcome {
            kind,
            result_id: pair_id(&a.stable_id(), &b.stable_id()),
            rule_id: a.rule_id.clone(),
            rule_version: a.rule_version,
            key: a.key.clone(),
            dimension: a.dimension.clone(),
            source_drawer_ids: source_ids,
            value_digests: digests,
            temporal_bases: {
                let mut bases = vec![
                    a.validity.canonical_bytes(),
                    b.validity.canonical_bytes(),
                ];
                bases.sort();
                bases
            },
            reasons,
        }
    };

    // 1. InvalidInput.
    if a.validity.is_malformed()
        || b.validity.is_malformed()
        || a.key.is_empty()
        || b.key.is_empty()
        || a.source_drawer_id.is_empty()
        || b.source_drawer_id.is_empty()
        || matches!(a.status, ConflictClaimStatus::Withdrawn | ConflictClaimStatus::Rejected)
        || matches!(b.status, ConflictClaimStatus::Withdrawn | ConflictClaimStatus::Rejected)
    {
        return outcome(ConflictOutcomeKind::InvalidInput, vec![ConflictReason::ParseAmbiguous]);
    }

    // 2. Irrelevant: different coordinate.
    if normalize::dimension_key(&a.key) != normalize::dimension_key(&b.key)
        || normalize::dimension_key(&a.dimension) != normalize::dimension_key(&b.dimension)
    {
        return outcome(ConflictOutcomeKind::Irrelevant, vec![ConflictReason::ScopeMismatch]);
    }

    let mut reasons = vec![ConflictReason::SameCoordinate];

    let Some(rule) = registry.rule_for_dimension(&a.dimension) else {
        reasons.push(ConflictReason::RuleUnknown);
        return outcome(ConflictOutcomeKind::CandidateReview, reasons);
    };

    // 3. Agreement.
    if a.value.is_equivalent(&b.value) {
        reasons.push(ConflictReason::ValueEquivalent);
        return outcome(ConflictOutcomeKind::Agreement, reasons);
    }

    // 4. CompatiblePlurality.
    match rule.cardinality {
        ConflictCardinality::Set | ConflictCardinality::Bag => {
            reasons.push(ConflictReason::CardinalityMulti);
            return outcome(ConflictOutcomeKind::CompatiblePlurality, reasons);
        }
        ConflictCardinality::Unknown => {
            reasons.push(ConflictReason::RuleUnknown);
            return outcome(ConflictOutcomeKind::CandidateReview, reasons);
        }
        ConflictCardinality::Single => {}
    }

    // 5. HistoricalSuccession.
    if accepted_supersession {
        reasons.push(ConflictReason::AcceptedSupersession);
        return outcome(ConflictOutcomeKind::HistoricalSuccession, reasons);
    }
    match a.validity.overlaps(&b.validity) {
        Some(false) => {
            reasons.push(ConflictReason::ValidityDisjoint);
            return outcome(ConflictOutcomeKind::HistoricalSuccession, reasons);
        }
        Some(true) => reasons.push(ConflictReason::ValidityOverlap),
        None => {
            // v0.1 policy `unknown-pair-concurrent` (M0 §5).
            if matches!(a.validity, TemporalBasis::Unknown)
                && matches!(b.validity, TemporalBasis::Unknown)
            {
                reasons.push(ConflictReason::ValidityUnknown);
            } else {
                reasons.push(ConflictReason::ValidityUnknown);
                return outcome(ConflictOutcomeKind::CandidateReview, reasons);
            }
        }
    }

    // 6. ProvenContradiction.
    reasons.push(ConflictReason::ValuesExclusive);
    outcome(ConflictOutcomeKind::ProvenContradiction, reasons)
}
