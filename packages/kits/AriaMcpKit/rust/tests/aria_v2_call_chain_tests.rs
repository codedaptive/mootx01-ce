//! Integration tests for [`aria_mcp::v2::call_chain`].
//!
//! Genuine twin of `Tests/AriaMCPTests/AriaV2CallChainTests.swift`.  Same
//! 14 test names (snake_case), same assertions, same order.  The two ports
//! differ only where language semantics require it:
//!
//! - Swift hooks are `async throws`; Rust hooks are sync `fn -> Result`.
//! - Swift uses `JSONValue` on both ingress and egress sides; Rust uses
//!   `crate::jsonrpc::JsonValue` (ingress) and `serde_json::Value` (egress)
//!   because the Rust v2 dispatch path is synchronous and the handler returns
//!   `serde_json::Value`.
//! - Swift error asserts use Swift Testing `#expect`; Rust uses `assert_eq!`.

use std::collections::BTreeMap;

use aria_mcp::jsonrpc::JsonValue;
use aria_mcp::v2::call_chain::{
    TransformHook, V2CallChain, V2CallChainError, V2ChainRegistration,
    V2EgressDecision, V2EgressHook, V2HaltReason, V2HookPhase,
};
use aria_mcp::v2::codec::strict_object;
use serde_json::Value as SjValue;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build a `JsonValue::Object` from pairs without a BTreeMap literal.
fn jobj(pairs: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
}

/// An egress transform that appends `marker` to a `SjValue::String` result.
/// Used across multiple tests to prove a hook ran and to track order.
fn append_marker(marker: &'static str) -> TransformHook {
    Box::new(move |_, result, _| {
        if let SjValue::String(s) = result {
            Ok(SjValue::String(format!("{s}{marker}")))
        } else {
            Ok(result)
        }
    })
}

/// An error type for test doubles.
#[derive(Debug)]
struct TestHookError(String);
impl std::fmt::Display for TestHookError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "test hook error: {}", self.0)
    }
}
impl std::error::Error for TestHookError {}
fn test_err(label: &str) -> Box<dyn std::error::Error + Send + Sync> {
    Box::new(TestHookError(label.to_owned()))
}

// ---------------------------------------------------------------------------
// 1
// ---------------------------------------------------------------------------

#[test]
fn empty_chain_returns_arguments_and_result_unchanged() {
    let chain = V2CallChain::new(vec![]).unwrap();
    let args = jobj([("query", JsonValue::String("x".to_owned()))]);
    let result = SjValue::String("original".to_owned());

    let ingress = chain.run_ingress("moot_memory_search", args.clone());
    let egress = chain.run_egress("moot_memory_search", result.clone(), &ingress);

    assert_eq!(ingress.arguments, args);
    assert_eq!(egress.result, result);
    assert_eq!(egress.halt, V2HaltReason::None);
    assert!(egress.failures.is_empty());
    assert!(ingress.failures.is_empty());
}

// ---------------------------------------------------------------------------
// 2
// ---------------------------------------------------------------------------

#[test]
fn ingress_strips_key_and_the_decoder_never_sees_it() {
    let mut raw = BTreeMap::new();
    raw.insert("query".to_owned(), JsonValue::String("x".to_owned()));
    raw.insert("echo_query".to_owned(), JsonValue::Bool(true));
    let raw_args = JsonValue::Object(raw);

    // Half 1: decode without the chain — must fail, error must name echo_query.
    let result_without_chain = strict_object(&raw_args, ["query"]);
    assert!(
        result_without_chain.is_err(),
        "strict_object should reject echo_query"
    );
    let err = result_without_chain.unwrap_err();
    assert_eq!(err.path, "$.echo_query");

    // Half 2: run ingress that strips echo_query, then decode — must succeed.
    let chain = V2CallChain::new(vec![V2ChainRegistration::new("echo-query-stripper")
        .with_ingress(
            10,
            Box::new(|_, args| {
                if let JsonValue::Object(mut dict) = args {
                    dict.remove("echo_query");
                    Ok((JsonValue::Object(dict), None))
                } else {
                    Ok((args, None))
                }
            }),
        )])
    .unwrap();

    let outcome = chain.run_ingress("moot_memory_search", raw_args);
    // The stripped arguments must decode cleanly with only "query" allowed.
    let decoded = strict_object(&outcome.arguments, ["query"]);
    assert!(decoded.is_ok(), "strict_object should succeed after stripping echo_query");
    let decoded_map = decoded.unwrap();
    // Verify the retained key is there.
    assert_eq!(decoded_map.get("query"), Some(&JsonValue::String("x".to_owned())));
}

// ---------------------------------------------------------------------------
// 3
// ---------------------------------------------------------------------------

#[test]
fn ingress_state_reaches_its_own_egress_hook_exactly() {
    let sentinel: JsonValue = JsonValue::String("distinctive-sentinel-abc123".to_owned());
    let sentinel_clone = sentinel.clone();

    let chain = V2CallChain::new(vec![V2ChainRegistration::new("state-carrier")
        .with_ingress(
            10,
            Box::new(move |_, args| Ok((args, Some(sentinel_clone.clone())))),
        )
        .with_egress(
            10,
            V2EgressHook::Transform(Box::new(move |_, _result, state| {
                if state == Some(&sentinel) {
                    Ok(SjValue::String("state-matched".to_owned()))
                } else {
                    Ok(SjValue::String("state-mismatch".to_owned()))
                }
            })),
        )])
    .unwrap();

    let ingress = chain.run_ingress("moot_memory_search", jobj([("q", JsonValue::String("y".to_owned()))]));
    let egress = chain.run_egress("moot_memory_search", SjValue::String("base".to_owned()), &ingress);

    assert_eq!(egress.result, SjValue::String("state-matched".to_owned()));
    assert_eq!(egress.halt, V2HaltReason::None);
    assert!(egress.failures.is_empty());
}

// ---------------------------------------------------------------------------
// 4
// ---------------------------------------------------------------------------

#[test]
fn state_is_delivered_only_to_its_own_concern() {
    let alpha_state = JsonValue::String("alpha-tag".to_owned());
    let beta_state = JsonValue::String("beta-tag".to_owned());

    let alpha_s = alpha_state.clone();
    let beta_s = beta_state.clone();
    let alpha_s2 = alpha_state.clone();
    let beta_s2 = beta_state.clone();
    let alpha_s3 = alpha_state.clone();
    let beta_s3 = beta_state.clone();

    let chain = V2CallChain::new(vec![
        V2ChainRegistration::new("alpha")
            .with_ingress(10, Box::new(move |_, args| Ok((args, Some(alpha_s.clone())))))
            .with_egress(
                10,
                V2EgressHook::Transform(Box::new(move |_, result, state| {
                    if let SjValue::String(s) = result {
                        // Explicitly verify beta's tag is absent.
                        if state == Some(&beta_s) {
                            return Ok(SjValue::String(format!("{s}|alpha-received-beta-state")));
                        }
                        if state == Some(&alpha_s2) {
                            return Ok(SjValue::String(format!("{s}|alpha-ok")));
                        }
                        Ok(SjValue::String(format!("{s}|alpha-wrong-state")))
                    } else {
                        Ok(result)
                    }
                })),
            ),
        V2ChainRegistration::new("beta")
            .with_ingress(20, Box::new(move |_, args| Ok((args, Some(beta_s2.clone())))))
            .with_egress(
                20,
                V2EgressHook::Transform(Box::new(move |_, result, state| {
                    if let SjValue::String(s) = result {
                        // Explicitly verify alpha's tag is absent.
                        if state == Some(&alpha_s3) {
                            return Ok(SjValue::String(format!("{s}|beta-received-alpha-state")));
                        }
                        if state == Some(&beta_s3) {
                            return Ok(SjValue::String(format!("{s}|beta-ok")));
                        }
                        Ok(SjValue::String(format!("{s}|beta-wrong-state")))
                    } else {
                        Ok(result)
                    }
                })),
            ),
    ])
    .unwrap();

    let ingress = chain.run_ingress("moot_memory_search", jobj([("q", JsonValue::String("y".to_owned()))]));
    let egress = chain.run_egress("moot_memory_search", SjValue::String("base".to_owned()), &ingress);

    assert_eq!(egress.result, SjValue::String("base|alpha-ok|beta-ok".to_owned()));
    assert_eq!(egress.halt, V2HaltReason::None);
    assert!(egress.failures.is_empty());
}

// ---------------------------------------------------------------------------
// 5
// ---------------------------------------------------------------------------

#[test]
fn egress_hooks_run_in_declared_order_not_textual_order() {
    // Part A: register "hi" (position 20) before "lo" (position 10) in
    // textual order.  Declared order must win: "lo" marker appears before "hi".
    let chain_a = V2CallChain::new(vec![
        // Textually first, declared position 20 — should run SECOND.
        V2ChainRegistration::new("hi").with_egress(20, V2EgressHook::Transform(append_marker("|hi"))),
        // Textually second, declared position 10 — should run FIRST.
        V2ChainRegistration::new("lo").with_egress(10, V2EgressHook::Transform(append_marker("|lo"))),
    ])
    .unwrap();

    let ingress_a = chain_a.run_ingress("t", jobj([]));
    let egress_a = chain_a.run_egress("t", SjValue::String("base".to_owned()), &ingress_a);
    assert_eq!(egress_a.result, SjValue::String("base|lo|hi".to_owned()));

    // Part B: same names, positions unchanged — textual order is now "lo"
    // before "hi", same declared positions, same result expected.
    let chain_b = V2CallChain::new(vec![
        V2ChainRegistration::new("lo").with_egress(10, V2EgressHook::Transform(append_marker("|lo"))),
        V2ChainRegistration::new("hi").with_egress(20, V2EgressHook::Transform(append_marker("|hi"))),
    ])
    .unwrap();

    let ingress_b = chain_b.run_ingress("t", jobj([]));
    let egress_b = chain_b.run_egress("t", SjValue::String("base".to_owned()), &ingress_b);
    assert_eq!(egress_b.result, SjValue::String("base|lo|hi".to_owned()));

    // Part C: swap positions so "lo" gets 20 and "hi" gets 10.  Order must flip.
    let chain_c = V2CallChain::new(vec![
        V2ChainRegistration::new("lo").with_egress(20, V2EgressHook::Transform(append_marker("|lo"))),
        V2ChainRegistration::new("hi").with_egress(10, V2EgressHook::Transform(append_marker("|hi"))),
    ])
    .unwrap();

    let ingress_c = chain_c.run_ingress("t", jobj([]));
    let egress_c = chain_c.run_egress("t", SjValue::String("base".to_owned()), &ingress_c);
    assert_eq!(egress_c.result, SjValue::String("base|hi|lo".to_owned()));
}

// ---------------------------------------------------------------------------
// 6
// ---------------------------------------------------------------------------

#[test]
fn a_firing_gate_skips_every_later_egress_hook() {
    let chain = V2CallChain::new(vec![
        V2ChainRegistration::new("guard").with_egress(
            10,
            V2EgressHook::Gate(Box::new(|_, _, _| {
                Ok(V2EgressDecision::Halt(SjValue::String("halted-by-guard".to_owned())))
            })),
        ),
        V2ChainRegistration::new("late-marker")
            .with_egress(20, V2EgressHook::Transform(append_marker("|late"))),
    ])
    .unwrap();

    let ingress = chain.run_ingress("t", jobj([]));
    let egress = chain.run_egress("t", SjValue::String("base".to_owned()), &ingress);

    assert_eq!(egress.result, SjValue::String("halted-by-guard".to_owned()));
    assert_eq!(egress.halt, V2HaltReason::GateFired("guard".to_owned()));
    // Late marker must be absent from the result.
    if let SjValue::String(ref s) = egress.result {
        assert!(!s.contains("|late"), "late marker must not appear after gate fires");
    }
    assert!(egress.failures.is_empty());
}

// ---------------------------------------------------------------------------
// 7
// ---------------------------------------------------------------------------

#[test]
fn a_passing_gate_lets_the_chain_complete() {
    let chain = V2CallChain::new(vec![
        V2ChainRegistration::new("permissive-guard").with_egress(
            10,
            V2EgressHook::Gate(Box::new(|_, result, _| Ok(V2EgressDecision::Pass(result)))),
        ),
        V2ChainRegistration::new("late-marker")
            .with_egress(20, V2EgressHook::Transform(append_marker("|late"))),
    ])
    .unwrap();

    let ingress = chain.run_ingress("t", jobj([]));
    let egress = chain.run_egress("t", SjValue::String("base".to_owned()), &ingress);

    assert_eq!(egress.result, SjValue::String("base|late".to_owned()));
    assert_eq!(egress.halt, V2HaltReason::None);
    assert!(egress.failures.is_empty());
}

// ---------------------------------------------------------------------------
// 8
// ---------------------------------------------------------------------------

#[test]
fn a_failing_transform_is_contained_and_the_chain_continues() {
    let chain = V2CallChain::new(vec![
        V2ChainRegistration::new("failing-transform").with_egress(
            10,
            V2EgressHook::Transform(Box::new(|_, _, _| Err(test_err("transform-intentional")))),
        ),
        V2ChainRegistration::new("surviving-marker")
            .with_egress(20, V2EgressHook::Transform(append_marker("|survived"))),
    ])
    .unwrap();

    let ingress = chain.run_ingress("t", jobj([]));
    let egress = chain.run_egress("t", SjValue::String("base".to_owned()), &ingress);

    assert_eq!(egress.result, SjValue::String("base|survived".to_owned()));
    assert_eq!(egress.halt, V2HaltReason::None);
    assert_eq!(egress.failures.len(), 1);
    assert_eq!(egress.failures[0].concern_name, "failing-transform");
    assert_eq!(egress.failures[0].phase, V2HookPhase::Egress);
}

// ---------------------------------------------------------------------------
// 9
// ---------------------------------------------------------------------------

#[test]
fn a_failing_gate_halts_the_chain_fail_closed() {
    let chain = V2CallChain::new(vec![
        V2ChainRegistration::new("erroring-gate").with_egress(
            10,
            V2EgressHook::Gate(Box::new(|_, _, _| Err(test_err("gate-intentional")))),
        ),
        V2ChainRegistration::new("late-marker")
            .with_egress(20, V2EgressHook::Transform(append_marker("|late"))),
    ])
    .unwrap();

    let ingress = chain.run_ingress("t", jobj([]));
    let egress = chain.run_egress("t", SjValue::String("base".to_owned()), &ingress);

    assert_eq!(egress.halt, V2HaltReason::GateFailed("erroring-gate".to_owned()));
    // Late marker must be absent — chain halted.
    if let SjValue::String(ref s) = egress.result {
        assert!(!s.contains("|late"), "late marker must not appear after gate error");
    }
    assert_eq!(egress.failures.len(), 1);
    assert_eq!(egress.failures[0].concern_name, "erroring-gate");
    assert_eq!(egress.failures[0].phase, V2HookPhase::Egress);
}

// ---------------------------------------------------------------------------
// 10
// ---------------------------------------------------------------------------

#[test]
fn a_failing_ingress_hook_discards_its_mutation_and_skips_its_egress_partner() {
    let chain = V2CallChain::new(vec![
        // Concern whose ingress returns Err — mutation discarded, egress skipped.
        V2ChainRegistration::new("failing-ingress")
            .with_ingress(
                10,
                Box::new(|_, _| Err(test_err("ingress-intentional"))),
            )
            .with_egress(
                10,
                V2EgressHook::Transform(append_marker("|failing-egress-ran")),
            ),
        // A second concern whose ingress mutates args and egress appends a marker.
        V2ChainRegistration::new("healthy")
            .with_ingress(
                20,
                Box::new(|_, args| {
                    if let JsonValue::Object(mut d) = args {
                        d.insert("healthy-key".to_owned(), JsonValue::Bool(true));
                        Ok((JsonValue::Object(d), Some(JsonValue::String("healthy-state".to_owned()))))
                    } else {
                        Ok((args, None))
                    }
                }),
            )
            .with_egress(20, V2EgressHook::Transform(append_marker("|healthy-ran"))),
    ])
    .unwrap();

    let args = jobj([("original", JsonValue::String("yes".to_owned()))]);
    let ingress = chain.run_ingress("t", args);

    // Failing ingress: no mutation visible (original key still present).
    if let JsonValue::Object(ref d) = ingress.arguments {
        assert_eq!(d.get("original"), Some(&JsonValue::String("yes".to_owned())));
    }
    // No state recorded for the failing concern.
    assert!(ingress.state.get("failing-ingress").is_none());
    // Healthy ingress: mutation present.
    if let JsonValue::Object(ref d) = ingress.arguments {
        assert_eq!(d.get("healthy-key"), Some(&JsonValue::Bool(true)));
    }
    assert_eq!(
        ingress.state.get("healthy"),
        Some(&JsonValue::String("healthy-state".to_owned()))
    );
    // Ingress failure recorded.
    assert_eq!(ingress.failures.len(), 1);
    assert_eq!(ingress.failures[0].concern_name, "failing-ingress");
    assert_eq!(ingress.failures[0].phase, V2HookPhase::Ingress);

    let egress = chain.run_egress("t", SjValue::String("base".to_owned()), &ingress);

    // Failing concern's egress must not have run — its marker is absent.
    if let SjValue::String(ref s) = egress.result {
        assert!(!s.contains("|failing-egress-ran"), "failing egress must not have run");
    }
    // Healthy concern's egress ran.
    assert_eq!(egress.result, SjValue::String("base|healthy-ran".to_owned()));
    assert_eq!(egress.halt, V2HaltReason::None);
    assert!(egress.failures.is_empty());
}

// ---------------------------------------------------------------------------
// 11
// ---------------------------------------------------------------------------

#[test]
fn a_failing_ingress_hook_of_a_gating_concern_halts_fail_closed() {
    let chain = V2CallChain::new(vec![
        // Gating concern whose ingress returns Err.
        V2ChainRegistration::new("lost-gate")
            .with_ingress(
                10,
                Box::new(|_, _| Err(test_err("gate-ingress-intentional"))),
            )
            .with_egress(
                10,
                V2EgressHook::Gate(Box::new(|_, result, _| Ok(V2EgressDecision::Pass(result)))),
            ),
        // Later transform — must NOT run because the gate's ingress failed.
        V2ChainRegistration::new("after-gate")
            .with_egress(20, V2EgressHook::Transform(append_marker("|after-gate-ran"))),
    ])
    .unwrap();

    let ingress = chain.run_ingress("t", jobj([]));
    let egress = chain.run_egress("t", SjValue::String("base".to_owned()), &ingress);

    // Rule 4: failed ingress on a gating concern halts fail-closed.
    assert_eq!(egress.halt, V2HaltReason::GateFailed("lost-gate".to_owned()));
    if let SjValue::String(ref s) = egress.result {
        assert!(!s.contains("|after-gate-ran"), "after-gate marker must not appear");
    }
}

// ---------------------------------------------------------------------------
// 12
// ---------------------------------------------------------------------------

#[test]
fn duplicate_concern_names_are_rejected_at_registration() {
    let result = V2CallChain::new(vec![
        V2ChainRegistration::new("shared-name"),
        V2ChainRegistration::new("shared-name"),
    ]);
    assert_eq!(
        result.unwrap_err(),
        V2CallChainError::DuplicateConcernName("shared-name".to_owned())
    );
}

// ---------------------------------------------------------------------------
// 13
// ---------------------------------------------------------------------------

#[test]
fn duplicate_ingress_positions_are_rejected_at_registration() {
    let result = V2CallChain::new(vec![
        V2ChainRegistration::new("concern-a")
            .with_ingress(10, Box::new(|_, args| Ok((args, None)))),
        V2ChainRegistration::new("concern-b")
            .with_ingress(10, Box::new(|_, args| Ok((args, None)))),
    ]);
    assert_eq!(
        result.unwrap_err(),
        V2CallChainError::DuplicateIngressPosition(10)
    );
}

// ---------------------------------------------------------------------------
// 14
// ---------------------------------------------------------------------------

#[test]
fn duplicate_egress_positions_are_rejected_at_registration() {
    let result = V2CallChain::new(vec![
        V2ChainRegistration::new("concern-a")
            .with_egress(10, V2EgressHook::Transform(Box::new(|_, r, _| Ok(r)))),
        V2ChainRegistration::new("concern-b")
            .with_egress(10, V2EgressHook::Transform(Box::new(|_, r, _| Ok(r)))),
    ]);
    assert_eq!(
        result.unwrap_err(),
        V2CallChainError::DuplicateEgressPosition(10)
    );
}
