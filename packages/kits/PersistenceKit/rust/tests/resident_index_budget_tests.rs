//! Tests for `ResidentIndexBudget::ceiling_bytes` resolution and forwarding.
//!
//! Covers behaviour (d) from MISSION_RS_01 Part 3: the budget field resolves
//! to the correct byte ceiling for fixed literal inputs so the twin Swift port
//! can assert the same literals and any divergence shows up as a failing test
//! rather than as silent result divergence.
//!
//! Fixed literals (both ports assert these exact numbers):
//!   - SystemFraction(0.25) against 8 GiB physical RAM → 2_147_483_648 bytes
//!   - Unbounded → None regardless of physical RAM
//!   - Bytes(n) → Some(n) independent of physical RAM detection
//!   - SystemFraction against undetectable platform (None) → None

use persistence_kit::{BackendConfiguration, EstateConfiguration, ResidentIndexBudget};

// ─────────────────────────────────────────────────────────────────────────────
// ceiling_bytes: fixed-literal cross-port agreement (behaviour d)
// ─────────────────────────────────────────────────────────────────────────────

/// SystemFraction(0.25) resolved against exactly 8 GiB (8_589_934_592 bytes)
/// must produce exactly 2_147_483_648 bytes (one quarter of 8 GiB).
///
/// This is the PRIMARY cross-port agreement literal. The Swift twin asserts the
/// same value against the same input. Any formula difference between ports shows
/// up here as a test failure rather than as silent result divergence.
///
/// Why 8 GiB: it is a power-of-two multiple of a rational, so `8_589_934_592 *
/// 0.25` is exactly representable as f64 and the cast to u64 is lossless. The
/// value is also realistic (a common test-machine configuration).
#[test]
fn system_fraction_quarter_against_8gib_is_exact_literal() {
    // 8 GiB in bytes — the canonical cross-port agreement input.
    let physical_ram: u64 = 8_589_934_592;
    let budget = ResidentIndexBudget::SystemFraction(0.25);
    // 8_589_934_592 × 0.25 = 2_147_483_648.0 exactly (both factors are
    // representable powers-of-two; no rounding). The Swift twin asserts
    // the same literal. If either port's formula drifts, both fail here.
    let ceiling = budget.ceiling_bytes(Some(physical_ram));
    assert_eq!(
        ceiling,
        Some(2_147_483_648),
        "SystemFraction(0.25) against 8 GiB must produce exactly 2_147_483_648 bytes"
    );
}

/// Unbounded resolves to None for every physical RAM value, including None
/// (undetectable platform). None means no cap — exact pre-admission behaviour.
#[test]
fn unbounded_resolves_to_none_regardless_of_ram() {
    let budget = ResidentIndexBudget::Unbounded;
    assert_eq!(
        budget.ceiling_bytes(None),
        None,
        "Unbounded must produce None when platform RAM is undetectable"
    );
    assert_eq!(
        budget.ceiling_bytes(Some(0)),
        None,
        "Unbounded must produce None even when reported RAM is zero"
    );
    assert_eq!(
        budget.ceiling_bytes(Some(8_589_934_592)),
        None,
        "Unbounded must produce None regardless of physical RAM amount"
    );
}

/// Bytes(n) is an absolute ceiling independent of physical RAM. It is honoured
/// even when the platform cannot detect RAM (None) and even when the detected
/// value is zero. Discarding an explicitly configured ceiling because detection
/// failed would leave the operator with no cap — the opposite of their intent.
///
/// Twin assertion: Swift `.bytes(N)` always returns N for any physicalMemoryBytes.
#[test]
fn bytes_ceiling_is_independent_of_physical_ram() {
    let budget = ResidentIndexBudget::Bytes(16_000_000);
    // Undetectable platform (None physical RAM) — ceiling is still honoured.
    assert_eq!(
        budget.ceiling_bytes(None),
        Some(16_000_000),
        "Bytes ceiling must be honoured even when physical RAM is undetectable"
    );
    // Zero reported RAM (silent detection failure) — ceiling is still honoured.
    assert_eq!(
        budget.ceiling_bytes(Some(0)),
        Some(16_000_000),
        "Bytes ceiling must be honoured when reported RAM is zero"
    );
    // Normal detection — same ceiling.
    assert_eq!(
        budget.ceiling_bytes(Some(8_589_934_592)),
        Some(16_000_000),
        "Bytes ceiling must be independent of detected physical RAM"
    );
}

/// SystemFraction on an undetectable platform (physical_ram = None) must
/// resolve to None, not a zero or guessed constant. A zero ceiling would
/// degrade every estate on the platform; a guessed constant could be wrong
/// in either direction. The safe answer is no cap (fail-open).
#[test]
fn system_fraction_undetectable_platform_resolves_to_none() {
    let budget = ResidentIndexBudget::SystemFraction(0.25);
    assert_eq!(
        budget.ceiling_bytes(None),
        None,
        "SystemFraction on an undetectable platform must not impose a cap (fail-open)"
    );
}

/// The default budget for a freshly constructed EstateConfiguration is
/// SystemFraction(0.25), matching the Swift default.
#[test]
fn estate_configuration_default_budget_is_system_fraction_quarter() {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    assert_eq!(
        config.resident_index_budget,
        ResidentIndexBudget::SystemFraction(0.25),
        "default resident_index_budget must be SystemFraction(0.25)"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// queue_sibling forwarding
// ─────────────────────────────────────────────────────────────────────────────

/// queue_sibling must carry the parent's resident_index_budget to the sibling.
/// An estate with a constrained budget must produce a sibling with the same
/// constraint so any VectorStore opened against the queue database applies the
/// same admission ceiling as the estate VectorStore.
#[test]
fn queue_sibling_inmemory_forwards_resident_index_budget() {
    let budget = ResidentIndexBudget::Bytes(4_096);
    let mut config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    config.resident_index_budget = budget.clone();

    let sibling = config.queue_sibling("queue.sqlite").expect("queue_sibling InMemory must succeed");

    assert_eq!(
        sibling.resident_index_budget,
        budget,
        "InMemory queue_sibling must forward parent's resident_index_budget unchanged"
    );
}

/// SQLite queue_sibling must also forward the resident_index_budget.
#[test]
fn queue_sibling_sqlite_forwards_resident_index_budget() {
    let budget = ResidentIndexBudget::Unbounded;
    let mut config = EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: "/tmp/estate.sqlite".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    config.resident_index_budget = budget.clone();

    let sibling = config.queue_sibling("queue.sqlite").expect("queue_sibling SQLite must succeed");

    assert_eq!(
        sibling.resident_index_budget,
        budget,
        "SQLite queue_sibling must forward parent's resident_index_budget unchanged"
    );
}
