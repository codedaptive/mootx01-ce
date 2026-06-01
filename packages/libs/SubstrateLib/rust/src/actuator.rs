// actuator.rs
//
// ActuatorKit per cookbook § 14. Mirror of
// glref-swift-ActuatorKit.swift.
//
// Three invariants enforced on every action:
//   I-21  allowlist gate
//   I-22  outcome reporting
//   I-23  reversibility tag (irreversible actions require confirm)

use std::collections::HashSet;
use substrate_types::hlc::HLC;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ActionKind {
    LocalNotification    = 1,
    CalendarInsert       = 2,
    CalendarRemove       = 3,
    ReminderInsert       = 4,
    OpenURL              = 5,
    WriteFile            = 6,
    ShellExecute         = 7,    // I-23 hard-irreversible
    SendMessage          = 8,
    AdjustHomeAutomation = 9,
    RequestUserInput     = 10,
    LogToAudit           = 11,
    RotatePrivateKey     = 12,   // I-23 hard-irreversible
}

impl ActionKind {
    pub fn is_reversible(&self) -> bool {
        matches!(self,
            ActionKind::LocalNotification
            | ActionKind::CalendarRemove
            | ActionKind::OpenURL
            | ActionKind::LogToAudit
            | ActionKind::RequestUserInput
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum OutcomeCategory {
    Resolved     = 0,
    Partial      = 1,
    Persisted    = 2,
    Regressed    = 3,
    TimedOut     = 4,
    NotAttempted = 5,
}

#[derive(Debug, Clone)]
pub struct ActuatorAllowlist {
    pub allowed: HashSet<ActionKind>,
}

impl ActuatorAllowlist {
    pub fn new(allowed: HashSet<ActionKind>) -> Self {
        Self { allowed }
    }

    pub fn contains(&self, kind: ActionKind) -> bool {
        self.allowed.contains(&kind)
    }

    /// Default allowlist: only localNotification and logToAudit.
    pub fn default_allowlist() -> Self {
        let mut allowed = HashSet::new();
        allowed.insert(ActionKind::LocalNotification);
        allowed.insert(ActionKind::LogToAudit);
        Self { allowed }
    }
}

#[derive(Debug, Clone)]
pub struct ActionProposal {
    pub kind: ActionKind,
    pub rationale: String,
    pub payload: Vec<u8>,
    pub outcome_category: Option<OutcomeCategory>,
    pub proposed_hlc: HLC,
    pub confirmation_token: Option<[u8; 16]>,
}

#[derive(Debug, Clone)]
pub struct ActuationResult {
    pub kind: ActionKind,
    pub outcome: OutcomeCategory,
    pub completed_hlc: HLC,
    pub error_message: Option<String>,
}

#[derive(Debug)]
pub enum ActuatorKitError {
    NotInAllowlist(ActionKind),
    IrreversibleWithoutConfirmation(ActionKind),
    HandlerUnavailable(ActionKind),
}

pub trait ActuatorHandler: Send + Sync {
    fn handles(&self, kind: ActionKind) -> bool;
    fn execute(&self, proposal: &ActionProposal) -> Result<ActuationResult, ActuatorKitError>;
}

pub struct ActuatorKit {
    pub allowlist: ActuatorAllowlist,
    pub handlers: Vec<Box<dyn ActuatorHandler>>,
    pub outcome_log: Vec<(HLC, ActionKind, OutcomeCategory)>,
}

impl ActuatorKit {
    pub fn new(allowlist: ActuatorAllowlist) -> Self {
        Self { allowlist, handlers: Vec::new(), outcome_log: Vec::new() }
    }

    pub fn register_handler(&mut self, handler: Box<dyn ActuatorHandler>) {
        self.handlers.push(handler);
    }

    /// Dispatch through allowlist, reversibility, handler. Enforces
    /// I-21, I-22, I-23.
    pub fn dispatch(&mut self, proposal: &ActionProposal)
                   -> Result<ActuationResult, ActuatorKitError> {
        if !self.allowlist.contains(proposal.kind) {
            return Err(ActuatorKitError::NotInAllowlist(proposal.kind));
        }
        if !proposal.kind.is_reversible() && proposal.confirmation_token.is_none() {
            return Err(ActuatorKitError::IrreversibleWithoutConfirmation(proposal.kind));
        }
        let handler = self.handlers.iter().find(|h| h.handles(proposal.kind));
        let handler = match handler {
            Some(h) => h,
            None => return Err(ActuatorKitError::HandlerUnavailable(proposal.kind)),
        };
        let result = handler.execute(proposal)?;
        self.outcome_log.push((result.completed_hlc, result.kind, result.outcome));
        Ok(result)
    }
}

/// Logging-only reference handler.
pub struct LoggingActuatorHandler;

impl ActuatorHandler for LoggingActuatorHandler {
    fn handles(&self, kind: ActionKind) -> bool {
        matches!(kind, ActionKind::LogToAudit | ActionKind::LocalNotification)
    }

    fn execute(&self, proposal: &ActionProposal) -> Result<ActuationResult, ActuatorKitError> {
        Ok(ActuationResult {
            kind: proposal.kind,
            outcome: OutcomeCategory::Resolved,
            completed_hlc: proposal.proposed_hlc,
            error_message: None,
        })
    }
}
