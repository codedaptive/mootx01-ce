// arm_register.rs
//
// Benchmark arm registry — names the arms available in a standard run and
// resolves the active arm from the environment. Rust twin of ArmRegister.swift.
//
// Two arms are available by default (no compilation flags, no special env):
//   "product-default" — naked arm; encoder enabled, no ablation active.
//   "no-encoder"      — encoder-absent ablation; activated by MOOT_BENCH_NO_ENCODER=1.
//
// Every other arm is a workshop instrument reachable only through its specific
// switch and is NOT included in DEFAULT_ARM_NAMES:
//   Other no_* ablations — behind their own env switches (future).

use std::collections::HashMap;
use std::sync::OnceLock;

/// Sorted names of the two default benchmark arms.
///
/// Used by gate assertions: the default list MUST contain exactly "no-encoder"
/// and "product-default".
///
/// Swift twin: `defaultArmNames` in ArmRegister.swift.
pub const DEFAULT_ARM_NAMES: &[&str] = &["no-encoder", "product-default"];

/// The product-baseline arm name: encoder enabled, no ablation active.
/// Active when no arm switch is set.
pub const ARM_PRODUCT_DEFAULT: &str = "product-default";

/// Encoder-absent ablation arm name. Standard regression instrument.
/// Active when MOOT_BENCH_NO_ENCODER=1 is set.
pub const ARM_NO_ENCODER: &str = "no-encoder";

/// Resolves the active arm name from the given environment map.
///
/// The seam form — accepts an explicit environment so callers can exercise
/// every branch without touching the process environment. Mirrors the shape of
/// `no_encoder_activation_seam_message_from_env()`.
///
/// Priority order:
/// 1. `MOOT_BENCH_NO_ENCODER=1` → "no-encoder"
/// 2. Otherwise → "product-default".
///
/// Tests call this directly with a synthetic map. Production code calls the
/// no-argument `resolve_active_arm_name()` which returns the process-wide
/// cached value.
///
/// Swift twin: `resolveActiveArmName(env:)` in ArmRegister.swift.
pub fn resolve_active_arm_name_from_env(env: &HashMap<String, String>) -> String {
    if env.get("MOOT_BENCH_NO_ENCODER").map(|v| v.as_str()) == Some("1") {
        return ARM_NO_ENCODER.to_string();
    }
    ARM_PRODUCT_DEFAULT.to_string()
}

// Process-wide cache. OnceLock guarantees thread-safe one-time initialization
// (equivalent to Swift's global-let dispatch_once semantics). The process
// environment is sampled once on first access; subsequent mutations of
// MOOT_BENCH_NO_ENCODER are invisible.
//
// This guarantees that every collect() in one process returns the same arm
// regardless of what happens to env vars between calls.
static CACHED_ARM_NAME: OnceLock<String> = OnceLock::new();

/// Resolves the active arm for this process.
///
/// Reads the process environment exactly once, at first call, and caches the
/// result permanently via `OnceLock`. Subsequent mutations of
/// `MOOT_BENCH_NO_ENCODER` are invisible —
/// every `collect()` call in the process returns the same arm.
///
/// Tests that need to exercise specific resolution branches should call
/// `resolve_active_arm_name_from_env()` with an explicit map instead of
/// mutating the live process environment.
///
/// `RunEnvironment::collect()` and `IdentityEnvironment::collect()` call this
/// to stamp the `benchmark_register_arm` field on every collected record.
///
/// Swift twin: `resolveActiveArmName()` in ArmRegister.swift.
pub fn resolve_active_arm_name() -> String {
    CACHED_ARM_NAME
        .get_or_init(|| {
            if std::env::var("MOOT_BENCH_NO_ENCODER").as_deref() == Ok("1") {
                return ARM_NO_ENCODER.to_string();
            }
            ARM_PRODUCT_DEFAULT.to_string()
        })
        .clone()
}

/// Returns a hard-error message when `MOOT_BENCH_NO_ENCODER=1` is set but
/// the no-encoder ablation has not been implemented.
///
/// The seam form — accepts an explicit environment map so tests can exercise
/// branches without touching the process environment.
///
/// Swift twin: `noEncoderActivationSeamMessage(env:)` in ArmRegister.swift.
pub fn no_encoder_activation_seam_message_from_env(
    env: &HashMap<String, String>,
) -> Option<String> {
    if env.get("MOOT_BENCH_NO_ENCODER").map(|v| v.as_str()) != Some("1") {
        return None;
    }
    Some(
        "[arm-register] MOOT_BENCH_NO_ENCODER=1 is set but the no-encoder \
ablation is not yet implemented. The harness would measure the product-default \
arm and record it as no-encoder — a mislabeled cell. Unset MOOT_BENCH_NO_ENCODER \
until the ablation is wired (encoder disabled at serve, embedding provider barred, \
or equivalent)."
            .to_string(),
    )
}

/// Returns a hard-error message when `MOOT_BENCH_NO_ENCODER=1` is set but
/// the no-encoder ablation has not been implemented.
///
/// The no-encoder arm is declared and part of the contract, but its
/// ACTIVATION is not yet wired: nothing provisions the estate differently,
/// nothing disables any encoder. Running with the switch set would produce
/// a product-default measurement recorded as "no-encoder" — a mislabeled
/// cell. A mislabeled cell is worse than no cell: every comparison against
/// it reads "the encoder makes no difference" when it measures nothing of
/// the kind.
///
/// `main()` calls this guard first — before any collect is attempted —
/// so the operator sees the refusal without a subprocess even starting.
/// `RunEnvironment::collect()` and `IdentityEnvironment::collect()` also
/// call it as a belt-and-suspenders check; they abort with `process::exit(1)`
/// when it returns `Some`. The guard fires at whichever call comes first;
/// `main()` is always earlier because `collect()` is reached only after
/// dispatch routes to a run subcommand.
///
/// When the ablation is implemented (encoder disabled at serve, embedding
/// provider barred, or equivalent), remove this guard. The arm declaration
/// and `DEFAULT_ARM_NAMES` entry stay — the arm is part of the contract;
/// it is the activation that was missing.
///
/// Swift twin: `noEncoderActivationSeamMessage(env:)` in ArmRegister.swift.
pub fn no_encoder_activation_seam_message() -> Option<String> {
    if std::env::var("MOOT_BENCH_NO_ENCODER").as_deref() != Ok("1") {
        return None;
    }
    Some(
        "[arm-register] MOOT_BENCH_NO_ENCODER=1 is set but the no-encoder \
ablation is not yet implemented. The harness would measure the product-default \
arm and record it as no-encoder — a mislabeled cell. Unset MOOT_BENCH_NO_ENCODER \
until the ablation is wired (encoder disabled at serve, embedding provider barred, \
or equivalent)."
            .to_string(),
    )
}

/// Returns `true` if `subcommand` is exempt from the no-encoder dispatch guard.
///
/// `main()` calls this before `no_encoder_activation_seam_message()`. Help
/// subcommands bypass the guard so that `mcp-benchmarker --help` always works
/// even when `MOOT_BENCH_NO_ENCODER=1` is set. Measuring subcommands are not
/// exempt; the guard fires for them.
///
/// The Rust binary has no `report` subcommand, so the exempt set is smaller
/// than the Swift equivalent. The Swift port additionally exempts `"report"`.
///
/// This is the single source of truth for the exempt set in the Rust port.
/// Both `main()` in main.rs and tests call this function — there is no second
/// copy of the list.
///
/// Swift twin: `isDispatchExemptFromNoEncoderGuard(_:)` in ArmRegister.swift.
pub fn is_no_encoder_dispatch_exempt(subcommand: &str) -> bool {
    matches!(subcommand, "--help" | "-h" | "help")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_arms_exact_set() {
        // Gate: default enumeration contains EXACTLY product-default and
        // no-encoder.
        assert!(
            DEFAULT_ARM_NAMES.contains(&"product-default"),
            "product-default must be in default arm names"
        );
        assert!(
            DEFAULT_ARM_NAMES.contains(&"no-encoder"),
            "no-encoder must be in default arm names"
        );

        // Count confirms there are exactly two — must update this assertion if
        // a third default arm is ever introduced, which requires a deliberate decision.
        assert_eq!(
            DEFAULT_ARM_NAMES.len(),
            2,
            "default arm count must be exactly 2"
        );
    }

    // resolve_active_arm_name_from_env seam tests use explicit maps — no POSIX
    // env mutations, no serialization, safe for parallel execution.

    #[test]
    fn resolve_product_default_when_no_env() {
        let arm = resolve_active_arm_name_from_env(&HashMap::new());
        assert_eq!(arm, "product-default");
    }

    #[test]
    fn resolve_no_encoder_when_switch_set() {
        let env: HashMap<String, String> = [("MOOT_BENCH_NO_ENCODER".to_string(), "1".to_string())]
            .into_iter()
            .collect();
        let arm = resolve_active_arm_name_from_env(&env);
        assert_eq!(arm, "no-encoder");
    }

    // ── D2: no-encoder activation guard ──────────────────────────────────────

    /// Guard returns Some with a message naming MOOT_BENCH_NO_ENCODER when the
    /// switch is set. The collect() paths check this and exit(1) — no record
    /// is written. Test drives no_encoder_activation_seam_message_from_env()
    /// directly (not collect()) so no process exit occurs.
    #[test]
    fn no_encoder_seam_message_when_switch_set() {
        let env: HashMap<String, String> = [("MOOT_BENCH_NO_ENCODER".to_string(), "1".to_string())]
            .into_iter()
            .collect();
        let msg = no_encoder_activation_seam_message_from_env(&env);

        assert!(
            msg.is_some(),
            "guard must return Some when MOOT_BENCH_NO_ENCODER=1"
        );
        let m = msg.unwrap();
        assert!(
            m.contains("MOOT_BENCH_NO_ENCODER"),
            "message must name the switch; got: {m}"
        );
        // "not yet implemented" names the missing activation — the arm is declared
        // but the actual ablation (encoder disabled at serve, etc.) is absent.
        assert!(
            m.contains("not yet implemented"),
            "message must state the activation is missing; got: {m}"
        );
    }

    /// Guard returns None when MOOT_BENCH_NO_ENCODER is not set — no refusal,
    /// collect() proceeds normally.
    #[test]
    fn no_encoder_seam_message_absent_without_switch() {
        let msg = no_encoder_activation_seam_message_from_env(&HashMap::new());
        assert!(
            msg.is_none(),
            "guard must return None when MOOT_BENCH_NO_ENCODER is absent; got: {:?}",
            msg
        );
    }
}
