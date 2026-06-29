// brain/scheduler/api.rs — surface vocabulary for the standing
// signals scheduler. Mirrors `SignalSchedule.swift`. The four
// emission classes from architecture spec §11.1 are the conformance
// gate's primary target.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

// Global monotonic counter mixed into SignalID entropy so that
// rapid-succession generate() calls (within the same nanosecond)
// always produce distinct identifiers. The counter is combined with
// the nanosecond timestamp via wrapping addition before the SplitMix64
// diffusion, which keeps the 32-hex output format identical while
// guaranteeing per-process uniqueness regardless of clock resolution.
static SIGNAL_ID_COUNTER: AtomicU64 = AtomicU64::new(0);

/// String alias for row identifiers. Matches Swift's `RowID = String`.
pub type RowID = String;

/// String alias for opaque estate identifiers. The Rust mirror does
/// not model the full `EstateHandle` value type because the Rust
/// version of the GeniusLocusKit coordinator is out of scope for
/// GLK-04; what the conformance gate verifies is the scheduler's
/// surface vocabulary, not the per-handle dispatch infrastructure.
pub type EstateHandleID = String;

/// Identifier minted when a signal is registered. Mirrors Swift's
/// `SignalID`. UUID rendering is a 32-char lowercase hex string
/// without hyphens — matches `JobID.generate`'s shape in QueueKit.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SignalID(pub String);

impl SignalID {
    /// Generate a fresh identifier. The Rust mirror uses the same
    /// 32-lowercase-hex format Swift's `SignalID.generate` emits so
    /// joined diagnostics across ports compare cleanly. The entropy
    /// mixes a monotonic atomic counter with `SystemTime` nanoseconds
    /// before SplitMix64 diffusion, guaranteeing uniqueness even when
    /// called multiple times within the same nanosecond.
    pub fn generate() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(1);
        // Combine the counter with the timestamp so rapid-succession calls
        // never collide even when the clock has not advanced.
        let counter = SIGNAL_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
        let seed = nanos.wrapping_add(counter.wrapping_mul(0x6C62272E07BB0142));
        let mut s = seed.wrapping_mul(0x9E3779B97F4A7C15);
        let mut buf = String::with_capacity(32);
        for _ in 0..4 {
            s ^= s >> 30;
            s = s.wrapping_mul(0xBF58476D1CE4E5B9);
            s ^= s >> 27;
            s = s.wrapping_mul(0x94D049BB133111EB);
            s ^= s >> 31;
            buf.push_str(&format!("{:016x}", s));
        }
        // 64 hex chars / 4 iters = 256 bits; trim to 32 chars to
        // match the Swift surface shape exactly.
        buf.truncate(32);
        SignalID(buf)
    }
}

/// Identifier minted by `subscribe`. Same shape and lifecycle as
/// `SignalID`. Distinct type to keep the subscribe/unsubscribe
/// argument-order check at compile time.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SubscriptionID(pub String);

impl SubscriptionID {
    pub fn generate() -> Self {
        SubscriptionID(SignalID::generate().0)
    }
}

/// Mirrors `SignalTrigger.swift`. Three families per architecture
/// spec §11.3. Condition predicates carry a name (for diagnostics)
/// and a synchronous closure for the Rust mirror's deterministic
/// gate. (Swift's variant is `async`; the Rust port's predicates are
/// pure functions of `SignalContext` so the parity test feeds them
/// the same vectors without an async runtime.)
#[derive(Clone)]
pub enum SignalTrigger {
    Event { name: String },
    Interval { seconds: Duration },
    Condition(ConditionPredicate),
}

#[derive(Clone)]
pub struct ConditionPredicate {
    pub name: String,
    pub evaluate: Arc<dyn Fn(&SignalContext) -> bool + Send + Sync>,
}

impl std::fmt::Debug for ConditionPredicate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConditionPredicate")
            .field("name", &self.name)
            .finish()
    }
}

/// Stable string for the trigger family. Surfaced in `SignalReport.trigger_tag`
/// so reports stay debug-printable without leaking the closure-bearing
/// trigger value. Mirrors Swift's `triggerTag(_:)` helper.
pub fn trigger_tag(t: &SignalTrigger) -> &'static str {
    match t {
        SignalTrigger::Event { .. } => "event",
        SignalTrigger::Interval { .. } => "interval",
        SignalTrigger::Condition(_) => "condition",
    }
}

/// Per-signal resource cost estimate per architecture spec §11.3.
/// Carried as metadata only — the scheduler does not budget against
/// it yet.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResourceCostEstimate {
    pub cpu: f64,
    pub memory_bytes: i64,
    pub io_ops: i64,
}

impl ResourceCostEstimate {
    pub const ZERO: ResourceCostEstimate = ResourceCostEstimate {
        cpu: 0.0,
        memory_bytes: 0,
        io_ops: 0,
    };
}

/// Concurrency policy from architecture spec §7.8.5. The serial-lane
/// decision means the Rust scheduler treats both variants as
/// single-instance — recorded in `SignalReport.concurrency_policy`
/// so the diagnostic surfaces the request and the enforcement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConcurrencyPolicy {
    Single,
    Bounded { max_instances: u32 },
}

/// Mirrors Swift's `MutationKind`. The two associated-value cases
/// carry stringly-typed payloads in this GLK scaffold; the conformance
/// gate checks the case-tag and (where applicable) the payload
/// vocabulary. Verb-wiring missions can reference locus_kit adjective
/// enum types directly once dispatch is wired through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MutationKind {
    Confirm,
    Reject,
    Contest,
    Resolve,
    Supersede,
    Revive,
    Accept,
    CorrectSensitivity(String),
    CorrectTrust(String),
}

impl MutationKind {
    pub fn tag(&self) -> &'static str {
        match self {
            MutationKind::Confirm => "confirm",
            MutationKind::Reject => "reject",
            MutationKind::Contest => "contest",
            MutationKind::Resolve => "resolve",
            MutationKind::Supersede => "supersede",
            MutationKind::Revive => "revive",
            MutationKind::Accept => "accept",
            MutationKind::CorrectSensitivity(_) => "correct_sensitivity",
            MutationKind::CorrectTrust(_) => "correct_trust",
        }
    }

    /// Decode from a stable tag string. Used when deserializing a
    /// `SignalJobEnvelope` from the queue payload. Associated-value variants
    /// (`CorrectSensitivity`, `CorrectTrust`) carry an empty string payload
    /// on decode because the original value is not re-serialized; callers
    /// that need the inner value should encode it separately in the envelope.
    /// Unrecognised tags map to `Confirm` as a safe default (the drain loop
    /// will route the emission and any downstream predicate can inspect the
    /// kind column).
    pub fn from_tag(s: &str) -> Self {
        match s {
            "confirm" => MutationKind::Confirm,
            "reject" => MutationKind::Reject,
            "contest" => MutationKind::Contest,
            "resolve" => MutationKind::Resolve,
            "supersede" => MutationKind::Supersede,
            "revive" => MutationKind::Revive,
            "accept" => MutationKind::Accept,
            "correct_sensitivity" => MutationKind::CorrectSensitivity(String::new()),
            "correct_trust" => MutationKind::CorrectTrust(String::new()),
            // Unrecognised tag: default to Confirm so the emission is not
            // silently dropped. The envelope's mutate_kind field carries the
            // original string for diagnostics.
            _ => MutationKind::Confirm,
        }
    }
}

/// Typed proposal vocabulary. Mirrors `ProposalKind.swift`.
///
/// Wire representation: `raw_value()` returns the stable string that
/// is written to the SQLite kind column and compared in conformance
/// vectors. `from_raw()` is the total inverse: unrecognised labels map
/// to `Other(s)`, matching Swift's `.other(String)` escape hatch.
///
/// The crate carries no serde dependency (see `matrix/persistence.rs`
/// comment), so the round-trip contract is expressed through
/// `raw_value` / `from_raw` instead of derive macros.
///
/// Case decisions (NK-1b Known Ambiguity 1):
///
/// Production labels — raw value matches Swift's `rawValue`:
///   `ByReferenceDrift`    ↔ "by_reference_drift"
///   `TournamentUpdate`    ↔ "tournament_update"
///   `MiningPattern`       ↔ "mining_pattern"
///   `DisciplineViolation` ↔ "discipline_violation"
///   `MutateCandidate`     ↔ "mutate_candidate"
///   `Enrichment`          ↔ "enrichment"
///
/// Test labels promoted to named cases:
///   `Amend`               ↔ "amend"
///   `TestPropose`         ↔ "test_propose"
///
/// `Other(String)` for stub placeholders (e.g. the single-char "k"
/// in class_tag_per_emission_matches_swift_strings).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ProposalKind {
    ByReferenceDrift,
    TournamentUpdate,
    MiningPattern,
    DisciplineViolation,
    MutateCandidate,
    /// Enrichment / Q-ID-assignment proposal. Filed by the maintenance
    /// daemon when deterministic re-inference cannot resolve a drawer's
    /// Wikidata Q-ID (cookbook §2.5; Q-ID-completion terminal workflow).
    Enrichment,
    Amend,
    TestPropose,
    Other(String),
}

impl ProposalKind {
    /// The stable wire string written to the SQLite kind column and
    /// used in conformance vectors. Matches Swift's `rawValue`.
    pub fn raw_value(&self) -> &str {
        match self {
            ProposalKind::ByReferenceDrift => "by_reference_drift",
            ProposalKind::TournamentUpdate => "tournament_update",
            ProposalKind::MiningPattern => "mining_pattern",
            ProposalKind::DisciplineViolation => "discipline_violation",
            ProposalKind::MutateCandidate => "mutate_candidate",
            ProposalKind::Enrichment => "enrichment",
            ProposalKind::Amend => "amend",
            ProposalKind::TestPropose => "test_propose",
            ProposalKind::Other(s) => s.as_str(),
        }
    }

    /// Decode from the stable wire string. Unrecognised strings map
    /// to `Other(s)`, matching Swift's total `init(rawValue:)`. The
    /// round-trip is exact: `from_raw(k.raw_value()) == k` for every
    /// non-`Other` variant.
    pub fn from_raw(s: &str) -> Self {
        match s {
            "by_reference_drift" => ProposalKind::ByReferenceDrift,
            "tournament_update" => ProposalKind::TournamentUpdate,
            "mining_pattern" => ProposalKind::MiningPattern,
            "discipline_violation" => ProposalKind::DisciplineViolation,
            "mutate_candidate" => ProposalKind::MutateCandidate,
            "enrichment" => ProposalKind::Enrichment,
            "amend" => ProposalKind::Amend,
            "test_propose" => ProposalKind::TestPropose,
            other => ProposalKind::Other(other.to_string()),
        }
    }
}

/// Brain-layer proposal frame. Mirrors `ProposalFrame.swift`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProposalFrame {
    pub target: RowID,
    /// Typed proposal taxonomy. See `ProposalKind` for the full
    /// vocabulary including production labels and test cases.
    pub kind: ProposalKind,
    pub justification: Option<String>,
}

/// Brain-layer association frame. Mirrors `AssociationFrame.swift`.
#[derive(Debug, Clone, PartialEq)]
pub struct AssociationFrame {
    pub a: RowID,
    pub b: RowID,
    pub weight: f64,
}

/// Diagnostic emission. Architecture spec §11.1 specifies this class
/// is "not a verb call; surfaced via `signal_status()`."
#[derive(Debug, Clone, PartialEq)]
pub struct DiagnosticReport {
    pub title: String,
    pub detail: String,
    /// Observed-at as nanoseconds since the Unix epoch. The Rust
    /// scheduler uses a Duration-since-epoch convention so test
    /// vectors are integer-comparable across ports.
    pub observed_at_nanos: i64,
}

/// Architecture spec §11.1. Exactly four cases — the conformance
/// gate asserts the order of `EMISSION_CLASS_TAGS` matches the Swift
/// reference and each `class_tag` returns the documented string.
#[derive(Debug, Clone, PartialEq)]
pub enum SignalEmission {
    Propose(ProposalFrame),
    Associate(AssociationFrame),
    MutateCandidate { row_id: RowID, kind: MutationKind },
    Diagnostic(DiagnosticReport),
}

impl SignalEmission {
    pub fn class_tag(&self) -> &'static str {
        match self {
            SignalEmission::Propose(_) => "propose",
            SignalEmission::Associate(_) => "associate",
            SignalEmission::MutateCandidate { .. } => "mutate_candidate",
            SignalEmission::Diagnostic(_) => "diagnostic",
        }
    }
}

/// The canonical ordered vocabulary of emission classes. The Swift
/// reference declares these in the same order; the parity test
/// asserts the array values match.
pub const EMISSION_CLASS_TAGS: [&str; 4] =
    ["propose", "associate", "mutate_candidate", "diagnostic"];

/// Caller-supplied signal description. Mirrors Swift's `SignalSpec`.
/// The `emit` closure is the only execution-bearing field.
#[derive(Clone)]
pub struct SignalSpec {
    pub name: String,
    pub trigger: SignalTrigger,
    pub resource_cost: ResourceCostEstimate,
    pub freshness_target: Duration,
    pub concurrency_policy: ConcurrencyPolicy,
    #[allow(clippy::type_complexity)]
    // emit closure type is intentional — factoring it into a type alias would obscure the contract
    pub emit: Arc<dyn Fn(&SignalContext) -> Vec<SignalEmission> + Send + Sync>,
}

impl std::fmt::Debug for SignalSpec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SignalSpec")
            .field("name", &self.name)
            .field("trigger_tag", &trigger_tag(&self.trigger))
            .field("resource_cost", &self.resource_cost)
            .field("freshness_target", &self.freshness_target)
            .field("concurrency_policy", &self.concurrency_policy)
            .finish()
    }
}

/// Context handed to a signal's `emit` closure. Mirrors Swift's
/// `SignalContext`. Times use nanoseconds since the Unix epoch so
/// the Rust gate compares against the Swift reference as integers.
#[derive(Debug, Clone)]
pub struct SignalContext {
    pub signal_id: SignalID,
    pub handle: EstateHandleID,
    pub now_nanos: i64,
    pub last_run_at_nanos: Option<i64>,
}

/// Operational state of a registered signal. Same vocabulary the
/// Swift mirror uses (`SignalState.tag`); the conformance gate
/// checks against the same strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignalState {
    Idle,
    Queued,
    Running,
    LastRan,
    Errored { reason: String },
}

impl SignalState {
    pub fn tag(&self) -> &'static str {
        match self {
            SignalState::Idle => "idle",
            SignalState::Queued => "queued",
            SignalState::Running => "running",
            SignalState::LastRan => "last_ran",
            SignalState::Errored { .. } => "errored",
        }
    }
}

/// Outcome of routing one `SignalEmission`. Mirrors Swift's
/// `SignalRouteOutcome`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignalRouteOutcome {
    Routed { verb: String },
    RoutedButVerbStubbed { verb: String },
    DiagnosticRecorded,
    RouteFailed { verb: String, reason: String },
}

/// Snapshot of one signal's status. Mirrors Swift's `SignalReport`.
#[derive(Debug, Clone, PartialEq)]
pub struct SignalReport {
    pub signal_id: SignalID,
    pub name: String,
    pub trigger_tag: String,
    pub state: SignalState,
    pub last_run_at_nanos: Option<i64>,
    pub last_emitted_at_nanos: Option<i64>,
    pub emission_count: u64,
    pub recent_diagnostics: Vec<DiagnosticReport>,
    pub recent_outcomes: Vec<SignalRouteOutcome>,
    pub concurrency_policy: ConcurrencyPolicy,
}
