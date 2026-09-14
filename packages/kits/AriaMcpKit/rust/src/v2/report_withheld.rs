//! Dispatch-local optional count, never session state. Rust dispatch is
//! synchronous; the guard restores the enclosing call on return or unwind.
use std::cell::RefCell;

#[derive(Default)]
struct State { enabled: bool, count: Option<usize> }
thread_local! { static CALL: RefCell<State> = RefCell::new(State::default()); }

pub(crate) struct CallGuard(State);
impl CallGuard {
    pub(crate) fn new() -> Self { Self(CALL.with(|s| s.replace(State::default()))) }
}
impl Drop for CallGuard {
    fn drop(&mut self) { CALL.with(|s| s.replace(std::mem::take(&mut self.0))); }
}
pub(crate) fn configure(value: Option<crate::jsonrpc::JsonValue>) {
    CALL.with(|s| s.borrow_mut().enabled = value.as_ref().and_then(|v| v.as_bool()) == Some(true));
}
pub(crate) fn enabled() -> bool { CALL.with(|s| s.borrow().enabled) }
pub(crate) fn record(count: usize) {
    CALL.with(|s| { let mut s = s.borrow_mut(); if s.enabled { s.count = Some(count); } });
}

/// Companion recall uses the recipe's real frame, internal origin and no trace
/// rows. GLK forwards Locus's count; this module never evaluates sensitivity.
pub(crate) fn recall(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    frame: locus_kit::filter::RecallFrame,
    now: i64,
) -> Result<(), ()> {
    if !enabled() { return Ok(()); }
    use genius_locus_kit::recall::*;
    let limit = frame.limit.unwrap_or(50);
    let request = GLKRecallRequest::new(frame, GLKRecallMode::LocusOnly, GLKRecallScoring::Raw,
        limit, RecallFallbackPolicy::AllowDegraded, RecallOrigin::Internal);
    let result = coordinator.recall_scored(handle, request, now).map_err(|_| ())?;
    record(result.withheld_by_sensitivity);
    Ok(())
}

pub(crate) fn egress(mut result: serde_json::Value) -> serde_json::Value {
    let count = CALL.with(|s| { let s = s.borrow(); if s.enabled { s.count } else { None } });
    if result["isError"] != true {
        if let (Some(count), Some(meta)) = (count, result["structuredContent"]["meta"].as_object_mut()) {
            meta.insert("withheldBySensitivity".into(), serde_json::json!(count));
        }
    }
    result
}
