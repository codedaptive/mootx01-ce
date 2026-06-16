//! observer_tests.rs — Rust parity for the resident observer enable decision
//! (DEBT-3). Mirrors the Swift `Observer.shouldEnable` tests in
//! packages/kits/AriaMcpKit/Tests/AriaResidentTests/ObserverTests.swift.
//!
//! The bounded-window and gate force-tests live in the IntellectusLib Rust
//! conformance suite (§8 RecentWindowSink in
//! packages/libs/IntellectusLib/rust/tests/intellectus_lib_tests.rs): the
//! window primitive is shared, so its overflow/eviction/gate proofs belong
//! with the primitive. This suite proves the AriaResident-layer enable
//! decision: env opt-in OR store flag.
//!
//! `observer_should_enable` reads the process-global `ARIA_MCP_OBSERVER` env
//! var, so the env-sensitive cases run in a single serialized test that sets
//! and clears the var (Rust runs tests in parallel threads within a binary;
//! env is process-global). The store-flag-only case is asserted with the env
//! var explicitly removed first.

use aria_mcp::runtime::observer_should_enable;

#[test]
fn store_flag_and_env_decision() {
    // Run the whole decision matrix in one test so the process-global
    // ARIA_MCP_OBSERVER env var is never raced by a parallel test.

    // Baseline: env var absent → decision follows the store flag only.
    std::env::remove_var("ARIA_MCP_OBSERVER");
    assert!(observer_should_enable(true), "store flag on must enable");
    assert!(!observer_should_enable(false), "both off must disable");

    // Truthy env values force enable even when the store flag is off.
    for truthy in ["1", "true", "TRUE", "yes", "On"] {
        std::env::set_var("ARIA_MCP_OBSERVER", truthy);
        assert!(
            observer_should_enable(false),
            "ARIA_MCP_OBSERVER={truthy} must enable on its own"
        );
    }

    // Falsey/garbage env values do not enable on their own.
    for falsey in ["0", "false", "no", "off", "", "banana"] {
        std::env::set_var("ARIA_MCP_OBSERVER", falsey);
        assert!(
            !observer_should_enable(false),
            "ARIA_MCP_OBSERVER={falsey} must not enable on its own"
        );
        // But the store flag still enables regardless of a falsey env var.
        assert!(
            observer_should_enable(true),
            "store flag on must enable even when ARIA_MCP_OBSERVER={falsey}"
        );
    }

    // Clean up so other test binaries are unaffected.
    std::env::remove_var("ARIA_MCP_OBSERVER");
}
