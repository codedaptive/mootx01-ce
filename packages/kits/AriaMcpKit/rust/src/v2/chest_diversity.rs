//! chest_diversity.rs — the per-call `chest_diversity` global modifier
//! (ADR-027 D3). Twin of Swift `AriaV2ChestDiversity`.
//!
//! Stripped at the door by the chain registry before strict decoding and
//! kept per call in thread-local state (the dispatcher runs one call per
//! thread, the same shape as `report_withheld`). `Some(true)` / `Some(false)`
//! is "on" / "off" given on the call; `None` is "not given", and the recall
//! operations then let the estate preference `chest_recall_diversity`
//! decide. Any other value is ignored, fail-open.
use std::cell::RefCell;

thread_local! { static CALL: RefCell<Option<bool>> = const { RefCell::new(None) }; }

/// Resets the call state on entry and restores the previous value on drop,
/// so a nested dispatch never inherits an outer call's modifier.
pub(crate) struct CallGuard(Option<bool>);
impl CallGuard {
    pub(crate) fn new() -> Self { Self(CALL.with(|s| s.replace(None))) }
}
impl Drop for CallGuard {
    fn drop(&mut self) { CALL.with(|s| s.replace(self.0.take())); }
}

pub(crate) fn configure(value: Option<crate::jsonrpc::JsonValue>) {
    let parsed = match value.as_ref().and_then(|v| v.as_str()) {
        Some("on") => Some(true),
        Some("off") => Some(false),
        _ => None,
    };
    CALL.with(|s| *s.borrow_mut() = parsed);
}

/// The override for the current call, `None` when none was given.
pub(crate) fn value() -> Option<bool> { CALL.with(|s| *s.borrow()) }

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jsonrpc::JsonValue;

    /// The call value parses on and off and ignores any other spelling.
    /// Twin of Swift `AriaV2ChestDiversityTests.callValueParses`.
    #[test]
    fn call_value_parses_on_off_and_ignores_the_rest() {
        let _guard = CallGuard::new();
        configure(Some(JsonValue::String("on".into())));
        assert_eq!(value(), Some(true));
        configure(Some(JsonValue::String("off".into())));
        assert_eq!(value(), Some(false));
        configure(Some(JsonValue::String("sideways".into())));
        assert_eq!(value(), None, "an unrecognised value is ignored, not an error");
        configure(None);
        assert_eq!(value(), None);
    }

    /// A nested dispatch starts clean and the outer call's value is restored
    /// when the inner guard drops.
    #[test]
    fn guard_isolates_nested_calls() {
        let _outer = CallGuard::new();
        configure(Some(JsonValue::String("on".into())));
        {
            let _inner = CallGuard::new();
            assert_eq!(value(), None, "the inner call does not inherit the outer modifier");
        }
        assert_eq!(value(), Some(true), "the outer value is restored");
    }
}
