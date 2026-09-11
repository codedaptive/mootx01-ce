//! ARIA v2 request-processing chain.
//!
//! This module implements [`V2CallChain`], the ARIA v2 pre/post processor:
//! three ordered hook sequences that wrap a single v2 tool call.
//!
//! * **Transform** — runs before argument decode.  A hook can remove a key
//!   the strict decoder rejects.  No concern registers on this phase in
//!   production; the slot is defined and reserved so future concerns can
//!   occupy a position without colliding.
//!
//! * **Ingress (record)** — runs after the frozen guard and after decode.
//!   Counting lives here because a refused call and a decode-failed call are
//!   not calls.
//!
//! * **Egress** — runs after the handler returns.
//!
//! The name "call_chain" is deliberate.  "Door" is already taken in this kit:
//! it is the recall-strategy selector on `moot_memory_search` (values: rrf /
//! matrixAware / raw / guess), backed by `DoorManifest` and
//! `provisionDoorConfig`, with its argument exercised in
//! `tests/aria_v2_memory_search_arg_tests.rs`.  A second unrelated "door"
//! module in the same kit would be read as recall-strategy code.

use std::collections::{HashMap, HashSet};

use serde_json::Value as SjValue;

use crate::jsonrpc::JsonValue;

// ---------------------------------------------------------------------------
// Egress decision
// ---------------------------------------------------------------------------

/// The outcome of a gate hook.  The return type makes the wrong thing
/// unrepresentable — a transform cannot halt, and a gate cannot silently pass
/// through without a decision.
pub enum V2EgressDecision {
    /// Gate passed: this result continues to the next egress hook.
    Pass(SjValue),
    /// Gate fired: this result becomes the final result and no later egress
    /// hook runs.
    Halt(SjValue),
}

// ---------------------------------------------------------------------------
// Hook aliases
// ---------------------------------------------------------------------------

/// Pre-decode transform hook: receives (tool_name, arguments), returns
/// mutated arguments.  Runs before `AriaSurfaceDecoder` so a hook can remove
/// a key the strict decoder rejects.  No state threading — simpler than
/// ingress because counting must not happen here.
/// Arc rather than Box so registrations can be cloned — the test seam
/// field on `Dispatcher` needs to survive across multiple `handle` calls
/// on a shared reference.  Semantically equivalent to Box for single-owner
/// use; Arc just adds the reference count.
pub type PreDecodeHook = std::sync::Arc<
    dyn Fn(&str, JsonValue) -> Result<JsonValue, Box<dyn std::error::Error + Send + Sync>>
        + Send
        + Sync,
>;

/// Ingress (record) hook: receives (tool_name, arguments), returns
/// (mutated_arguments, optional_state).  The returned arguments replace the
/// current arguments and feed the next ingress hook.  The state is keyed by
/// concern name and delivered only to that concern's egress hook.
pub type IngressHook = Box<
    dyn Fn(&str, JsonValue) -> Result<(JsonValue, Option<JsonValue>), Box<dyn std::error::Error + Send + Sync>>
        + Send
        + Sync,
>;

/// Transform egress hook: receives (tool_name, result, optional_state),
/// returns a new result.  Cannot halt the chain.
pub type TransformHook = Box<
    dyn Fn(&str, SjValue, Option<&JsonValue>) -> Result<SjValue, Box<dyn std::error::Error + Send + Sync>>
        + Send
        + Sync,
>;

/// Gate egress hook: receives (tool_name, result, optional_state), returns a
/// decision.  A `Halt` decision ends the chain immediately.
pub type GateHook = Box<
    dyn Fn(&str, SjValue, Option<&JsonValue>) -> Result<V2EgressDecision, Box<dyn std::error::Error + Send + Sync>>
        + Send
        + Sync,
>;

// ---------------------------------------------------------------------------
// Egress hook kind
// ---------------------------------------------------------------------------

/// Two kinds of egress hook.  The enum is the only representation — there is
/// no `is_gate` boolean.
pub enum V2EgressHook {
    Transform(TransformHook),
    Gate(GateHook),
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// One concern's contribution to the chain.
///
/// A concern may declare a transform hook, an ingress hook, an egress hook, any
/// combination, or none.  Position lives in independent spaces for each phase:
/// a transform position of 10, an ingress position of 10, and an egress
/// position of 10 are all unrelated.  Ordering within each chain is by
/// ascending position; duplicate positions within a chain are rejected at
/// [`V2CallChain::new`].
pub struct V2ChainRegistration {
    pub concern_name: String,
    /// Pre-decode argument transform.  Runs before the strict argument decoder
    /// so a hook can remove a key it would otherwise reject.
    pub transform: Option<(i32, PreDecodeHook)>,
    pub ingress: Option<(i32, IngressHook)>,
    pub egress: Option<(i32, V2EgressHook)>,
}

impl V2ChainRegistration {
    /// Construct a registration with optional transform, ingress and egress
    /// contributions.
    pub fn new(concern_name: impl Into<String>) -> Self {
        Self {
            concern_name: concern_name.into(),
            transform: None,
            ingress: None,
            egress: None,
        }
    }

    /// Set the pre-decode transform hook.
    pub fn with_transform(mut self, position: i32, hook: PreDecodeHook) -> Self {
        self.transform = Some((position, hook));
        self
    }

    /// Set the ingress hook.
    pub fn with_ingress(mut self, position: i32, hook: IngressHook) -> Self {
        self.ingress = Some((position, hook));
        self
    }

    /// Clone just the transform component into a new registration.
    ///
    /// Used by the test seam on `Dispatcher` to consume pre-decode registrations
    /// without requiring `&mut self` on `handle`.  Ingress and egress hooks are
    /// `Box<dyn Fn>` and cannot be cloned; the transform hook is `Arc<dyn Fn>` and
    /// can be.  Only the transform field is carried over.
    pub(crate) fn clone_transform_only(&self) -> Self {
        Self {
            concern_name: self.concern_name.clone(),
            transform: self.transform.as_ref().map(|(pos, hook)| (*pos, std::sync::Arc::clone(hook))),
            ingress: None,
            egress: None,
        }
    }

    /// Set the egress hook.
    pub fn with_egress(mut self, position: i32, hook: V2EgressHook) -> Self {
        self.egress = Some((position, hook));
        self
    }
}

// ---------------------------------------------------------------------------
// Construction error
// ---------------------------------------------------------------------------

/// Errors produced at chain-construction time; none are deferred to run time.
#[derive(Debug, PartialEq, Eq)]
pub enum V2CallChainError {
    DuplicateConcernName(String),
    DuplicateTransformPosition(i32),
    DuplicateIngressPosition(i32),
    DuplicateEgressPosition(i32),
}

impl std::fmt::Display for V2CallChainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateConcernName(n) => write!(f, "duplicate concern name: {n}"),
            Self::DuplicateTransformPosition(p) => write!(f, "duplicate transform position: {p}"),
            Self::DuplicateIngressPosition(p) => write!(f, "duplicate ingress position: {p}"),
            Self::DuplicateEgressPosition(p) => write!(f, "duplicate egress position: {p}"),
        }
    }
}

impl std::error::Error for V2CallChainError {}

// ---------------------------------------------------------------------------
// Hook failure record
// ---------------------------------------------------------------------------

/// The phase in which a hook error was contained.
#[derive(Debug, PartialEq, Eq)]
pub enum V2HookPhase {
    Transform,
    Ingress,
    Egress,
}

/// A record of a hook error that was contained by the chain.
///
/// The chain contains Rust `Err` returns.  It does not contain panics, which
/// are uncatchable at this level in normal (non-unwinding) Rust and propagate
/// normally.
pub struct V2HookFailure {
    /// The concern whose hook returned `Err`.
    pub concern_name: String,
    /// Which chain the error occurred in.
    pub phase: V2HookPhase,
    /// Human-readable description of the error, captured at containment time.
    pub error_description: String,
}

// ---------------------------------------------------------------------------
// Halt reason
// ---------------------------------------------------------------------------

/// Why (and by whom) the egress chain stopped early, if it did.
#[derive(Debug, PartialEq, Eq)]
pub enum V2HaltReason {
    /// The chain ran to completion with no gate intervention.
    None,
    /// A gate hook returned [`V2EgressDecision::Halt`]; `concern` names it.
    GateFired(String),
    /// A gate hook returned `Err`; `concern` names it.  Fail-closed: the chain
    /// halted even though the gate never produced a decision.
    GateFailed(String),
}

// ---------------------------------------------------------------------------
// Outcomes
// ---------------------------------------------------------------------------

/// Result of running the ingress chain.
pub struct V2IngressOutcome {
    /// The final arguments after all successful ingress mutations.
    pub arguments: JsonValue,
    /// Per-concern state keyed by concern name.  Only present for concerns
    /// whose ingress hook succeeded and returned `Some` state.
    pub state: HashMap<String, JsonValue>,
    /// Names of concerns whose ingress hook returned `Err`.
    pub failed_concerns: HashSet<String>,
    /// Failure records in hook-execution order.
    pub failures: Vec<V2HookFailure>,
}

/// Result of running the egress chain.
pub struct V2EgressOutcome {
    /// The final result after all egress hooks ran (or the chain halted).
    pub result: SjValue,
    /// Whether and why the egress chain was cut short.
    pub halt: V2HaltReason,
    /// Failure records in hook-execution order.
    pub failures: Vec<V2HookFailure>,
}

/// Result of running the pre-decode transform chain.
pub struct V2TransformOutcome {
    /// The arguments after all successful transform mutations.
    pub arguments: JsonValue,
    /// Failure records in hook-execution order.
    pub failures: Vec<V2HookFailure>,
}

// ---------------------------------------------------------------------------
// Call chain
// ---------------------------------------------------------------------------

/// The ARIA v2 pre/post processor.
///
/// Build-once and immutable.  Validated at construction, then `Send + Sync`.
/// The three hook chains (transform, ingress, egress) run in ascending
/// declared-position order; textual registration order has no effect.
///
/// **Transform** runs before argument decode.  The transform phase runs before
/// decode so a hook can remove a key the strict decoder rejects.  No concern
/// registers on this phase in production.
///
/// **Ingress (record)** runs after the frozen guard and after decode.  Counting
/// runs here because a refused call is not a call and a decode-failed call is
/// not a call.  A hook receives the tool name and the arguments, may mutate
/// them, and may record state for delivery to its own egress hook only.
///
/// **Egress** runs after the handler returns.  A hook receives the tool name,
/// the current result, and any state its own ingress hook recorded.
///
/// **Throw policy** (all four rules, no hook error escapes the chain):
/// 1. A transform hook that returns `Err`: arguments unchanged, chain continues,
///    failure recorded.
/// 2. An egress gate hook that returns `Err`: chain halts fail-closed.  A guard
///    that cannot decide must not be assumed to permit.
/// 3. An ingress hook that returns `Err`: arguments unchanged, no state
///    recorded, that concern's egress hook does not run.
/// 4. If the failed-ingress concern has a gate egress hook: chain halts
///    fail-closed at that egress position (rule 2 applied retroactively).
///
/// **Scope of containment:** Rust `Err` returns are contained.  Panics are not
/// catchable by this component in normal (non-unwinding) Rust and propagate
/// normally.
///
/// This component does **not** synthesize a refusal payload on a halt.  It
/// halts, returns the payload unmodified, and tells the caller why.  The caller
/// renders.  This keeps the component free of the envelope types, which differ
/// between ports.
pub struct V2CallChain {
    /// Pre-decode transform hooks sorted by declared position (ascending).
    transform_chain: Vec<(String, PreDecodeHook)>,
    /// Ingress (record) hooks sorted by declared position (ascending).
    ingress_chain: Vec<(String, IngressHook)>,
    /// Egress hooks sorted by declared position (ascending).
    egress_chain: Vec<(String, V2EgressHook)>,
    /// Names of concerns whose egress hook is a gate (for fail-closed lookup).
    gating_concerns: HashSet<String>,
}

impl std::fmt::Debug for V2CallChain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("V2CallChain")
            .field("transform_hooks", &self.transform_chain.len())
            .field("ingress_hooks", &self.ingress_chain.len())
            .field("egress_hooks", &self.egress_chain.len())
            .finish_non_exhaustive()
    }
}

impl V2CallChain {
    /// Construct the chain from a list of registrations.
    ///
    /// Validation happens here; [`run_transform`], [`run_ingress`] and
    /// [`run_egress`] never fail.
    ///
    /// # Errors
    ///
    /// - [`V2CallChainError::DuplicateConcernName`] if two registrations share a
    ///   concern name.
    /// - [`V2CallChainError::DuplicateTransformPosition`] if two transform hooks
    ///   share a declared position.
    /// - [`V2CallChainError::DuplicateIngressPosition`] if two ingress hooks
    ///   share a declared position.
    /// - [`V2CallChainError::DuplicateEgressPosition`] if two egress hooks share
    ///   a declared position.
    pub fn new(registrations: Vec<V2ChainRegistration>) -> Result<Self, V2CallChainError> {
        let mut seen_names = HashSet::new();
        for r in &registrations {
            if !seen_names.insert(r.concern_name.clone()) {
                return Err(V2CallChainError::DuplicateConcernName(r.concern_name.clone()));
            }
        }

        // Collect transform hooks, validating positions.
        let mut transform_entries: Vec<(i32, String, PreDecodeHook)> = Vec::new();
        let mut seen_transform_pos = HashSet::new();

        // Collect ingress hooks, validating positions.
        let mut ingress_entries: Vec<(i32, String, IngressHook)> = Vec::new();
        let mut seen_ingress_pos = HashSet::new();

        // Collect egress hooks, validating positions.
        let mut egress_entries: Vec<(i32, String, V2EgressHook)> = Vec::new();
        let mut seen_egress_pos = HashSet::new();
        let mut gating_concerns = HashSet::new();

        for r in registrations {
            if let Some((pos, hook)) = r.transform {
                if !seen_transform_pos.insert(pos) {
                    return Err(V2CallChainError::DuplicateTransformPosition(pos));
                }
                transform_entries.push((pos, r.concern_name.clone(), hook));
            }
            if let Some((pos, hook)) = r.ingress {
                if !seen_ingress_pos.insert(pos) {
                    return Err(V2CallChainError::DuplicateIngressPosition(pos));
                }
                ingress_entries.push((pos, r.concern_name.clone(), hook));
            }
            if let Some((pos, hook)) = r.egress {
                if !seen_egress_pos.insert(pos) {
                    return Err(V2CallChainError::DuplicateEgressPosition(pos));
                }
                if matches!(&hook, V2EgressHook::Gate(_)) {
                    gating_concerns.insert(r.concern_name.clone());
                }
                egress_entries.push((pos, r.concern_name, hook));
            }
        }

        transform_entries.sort_by_key(|(pos, _, _)| *pos);
        ingress_entries.sort_by_key(|(pos, _, _)| *pos);
        egress_entries.sort_by_key(|(pos, _, _)| *pos);

        Ok(Self {
            transform_chain: transform_entries.into_iter().map(|(_, n, h)| (n, h)).collect(),
            ingress_chain: ingress_entries.into_iter().map(|(_, n, h)| (n, h)).collect(),
            egress_chain: egress_entries.into_iter().map(|(_, n, h)| (n, h)).collect(),
            gating_concerns,
        })
    }

    // -----------------------------------------------------------------------
    // Transform (pre-decode)
    // -----------------------------------------------------------------------

    /// Run all pre-decode transform hooks in ascending declared-position order.
    ///
    /// Never fails.  Errors from hooks are contained and recorded; the prior
    /// arguments carry forward on error.
    pub fn run_transform(&self, tool_name: &str, arguments: JsonValue) -> V2TransformOutcome {
        let mut current = arguments;
        let mut failures: Vec<V2HookFailure> = Vec::new();

        for (name, hook) in &self.transform_chain {
            match hook(tool_name, current.clone()) {
                Ok(new_args) => {
                    current = new_args;
                }
                Err(e) => {
                    failures.push(V2HookFailure {
                        concern_name: name.clone(),
                        phase: V2HookPhase::Transform,
                        error_description: e.to_string(),
                    });
                    // Arguments unchanged; chain continues.
                }
            }
        }

        V2TransformOutcome {
            arguments: current,
            failures,
        }
    }

    // -----------------------------------------------------------------------
    // Ingress (record)
    // -----------------------------------------------------------------------

    /// Run all ingress (record) hooks in ascending declared-position order.
    ///
    /// Never fails.  Errors from hooks are contained and recorded.
    pub fn run_ingress(&self, tool_name: &str, arguments: JsonValue) -> V2IngressOutcome {
        let mut current = arguments;
        let mut state: HashMap<String, JsonValue> = HashMap::new();
        let mut failed_concerns: HashSet<String> = HashSet::new();
        let mut failures: Vec<V2HookFailure> = Vec::new();

        for (name, hook) in &self.ingress_chain {
            match hook(tool_name, current.clone()) {
                Ok((new_args, new_state)) => {
                    current = new_args;
                    if let Some(s) = new_state {
                        state.insert(name.clone(), s);
                    }
                }
                Err(e) => {
                    failed_concerns.insert(name.clone());
                    failures.push(V2HookFailure {
                        concern_name: name.clone(),
                        phase: V2HookPhase::Ingress,
                        error_description: e.to_string(),
                    });
                    // Arguments unchanged; no state recorded for this concern.
                }
            }
        }

        V2IngressOutcome {
            arguments: current,
            state,
            failed_concerns,
            failures,
        }
    }

    // -----------------------------------------------------------------------
    // Egress
    // -----------------------------------------------------------------------

    /// Run all egress hooks in ascending declared-position order.
    ///
    /// Never fails.  Gate errors and fire decisions halt the chain immediately.
    /// Transform errors are contained and the prior result carries forward.
    ///
    /// `ingress_outcome` delivers each concern's ingress-recorded state to its
    /// own egress hook, and communicates which concerns' ingress hooks failed.
    pub fn run_egress(&self, tool_name: &str, result: SjValue, ingress_outcome: &V2IngressOutcome) -> V2EgressOutcome {
        let mut current = result;
        let mut failures: Vec<V2HookFailure> = Vec::new();

        for (name, hook) in &self.egress_chain {
            // Rules 3+4: if ingress failed for this concern, apply containment.
            if ingress_outcome.failed_concerns.contains(name.as_str()) {
                if self.gating_concerns.contains(name.as_str()) {
                    // Rule 4: failed ingress on a gating concern halts fail-closed.
                    return V2EgressOutcome {
                        result: current,
                        halt: V2HaltReason::GateFailed(name.clone()),
                        failures,
                    };
                }
                // Rule 3: non-gating concern — skip its egress hook entirely.
                continue;
            }

            let concern_state = ingress_outcome.state.get(name.as_str());

            match hook {
                V2EgressHook::Transform(f) => {
                    // Rule 1: a transform that returns Err is contained.
                    match f(tool_name, current.clone(), concern_state) {
                        Ok(new_result) => current = new_result,
                        Err(e) => {
                            failures.push(V2HookFailure {
                                concern_name: name.clone(),
                                phase: V2HookPhase::Egress,
                                error_description: e.to_string(),
                            });
                            // Result unchanged; chain continues.
                        }
                    }
                }
                V2EgressHook::Gate(f) => {
                    // Rule 2: a gate that returns Err halts fail-closed.
                    match f(tool_name, current.clone(), concern_state) {
                        Ok(V2EgressDecision::Pass(new_result)) => current = new_result,
                        Ok(V2EgressDecision::Halt(halt_result)) => {
                            return V2EgressOutcome {
                                result: halt_result,
                                halt: V2HaltReason::GateFired(name.clone()),
                                failures,
                            };
                        }
                        Err(e) => {
                            failures.push(V2HookFailure {
                                concern_name: name.clone(),
                                phase: V2HookPhase::Egress,
                                error_description: e.to_string(),
                            });
                            return V2EgressOutcome {
                                result: current,
                                halt: V2HaltReason::GateFailed(name.clone()),
                                failures,
                            };
                        }
                    }
                }
            }
        }

        V2EgressOutcome {
            result: current,
            halt: V2HaltReason::None,
            failures,
        }
    }
}
