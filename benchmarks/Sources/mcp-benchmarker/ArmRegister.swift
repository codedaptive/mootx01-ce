// ArmRegister.swift
//
// Benchmark arm registry — names the arms available in a standard run and
// resolves the active arm from the environment.
//
// Two arms are available by default (no compilation flags, no special env):
//   product-default — naked arm; encoder enabled, no ablation active.
//   no-encoder      — encoder-absent ablation; activated by MOOT_BENCH_NO_ENCODER=1.
//
// Every other arm is a workshop instrument reachable only through its specific
// switch and is NOT enumerated in DefaultBenchmarkArm.allCases:
//   Other no_* ablations — behind their own env switches (future).
//
// This file is the ONE place that names arms and says which are default. Use
// it for gate assertions, filename labelling, and per-row arm stamping.

import Foundation

/// The two arms available by default in a standard benchmark run.
///
/// Only these two appear in the default enumeration. Other `no_*` ablations
/// are workshop instruments reachable only through their specific switch —
/// never listed here.
///
/// Use `DefaultBenchmarkArm.allCases` to enumerate the default set or
/// `resolveActiveArmName()` to read the active arm from the environment.
public enum DefaultBenchmarkArm: String, Sendable, CaseIterable {
    /// The product baseline: encoder enabled, no ablation active.
    /// Active when no arm switch is set.
    case productDefault = "product-default"
    /// Encoder-absent ablation: the product baseline run without vector-search
    /// encoding. Standard regression instrument — one extra cell per lane.
    /// Active when MOOT_BENCH_NO_ENCODER=1 is set.
    case noEncoder = "no-encoder"
}

/// Sorted names of the two default benchmark arms.
///
/// Used by gate assertions: the default enumeration MUST contain exactly
/// "no-encoder" and "product-default".
///
/// Rust twin: `DEFAULT_ARM_NAMES` in arm_register.rs.
public let defaultArmNames: [String] = DefaultBenchmarkArm.allCases
    .map(\.rawValue)
    .sorted()

/// Resolves the active arm name from the given environment dict.
///
/// The seam form — accepts an explicit environment so callers can exercise
/// every branch without touching the process environment. Mirrors the shape of
/// `noEncoderActivationSeamMessage(env:)`.
///
/// Priority order:
/// 1. `MOOT_BENCH_NO_ENCODER=1` → "no-encoder"
/// 2. Otherwise → "product-default".
///
/// Tests call this overload directly with a synthetic dict. Production code
/// calls the no-argument `resolveActiveArmName()` which returns the
/// process-wide cached value.
///
/// Rust twin: `resolve_active_arm_name_from_env()` in arm_register.rs.
public func resolveActiveArmName(env: [String: String]) -> String {
    if env["MOOT_BENCH_NO_ENCODER"] == "1" {
        return DefaultBenchmarkArm.noEncoder.rawValue
    }
    return DefaultBenchmarkArm.productDefault.rawValue
}

// Process-wide cache. Swift global-let initialization has dispatch_once
// semantics — evaluated exactly once, safely, on first access. The process
// environment is sampled here; subsequent mutations of MOOT_BENCH_NO_ENCODER
// are invisible to resolveActiveArmName().
//
// This guarantees that every collect() in one process returns the same arm
// regardless of what happens to env vars between calls — without this cache,
// a mid-run env mutation would stamp different arms onto records from the same
// run, producing mislabeled cells that silently corrupt the comparison matrix.
private let _resolvedArmName: String = resolveActiveArmName(
    env: ProcessInfo.processInfo.environment
)

/// Resolves the active arm for this process.
///
/// Reads the process environment exactly once, at first access, and caches
/// the result permanently. Subsequent mutations of `MOOT_BENCH_NO_ENCODER`
/// are invisible — every `collect()` call in the
/// process returns the same arm.
///
/// Tests that need to exercise specific resolution branches should call
/// `resolveActiveArmName(env:)` with an explicit dict instead of mutating
/// the live process environment.
///
/// `RunEnvironment.collect()` and `IdentityEnvironment.collect()` call this
/// to stamp `benchmarkRegisterArm` on every collected record.
///
/// Rust twin: `resolve_active_arm_name()` in arm_register.rs.
public func resolveActiveArmName() -> String { _resolvedArmName }

/// Returns a hard-error message when `MOOT_BENCH_NO_ENCODER=1` is set but
/// the no-encoder ablation has not been implemented.
///
/// The no-encoder arm is declared and part of the contract (see
/// `DefaultBenchmarkArm.noEncoder`), but its ACTIVATION is not yet wired:
/// nothing provisions the estate differently, nothing disables any encoder.
/// Running with the switch set would produce a product-default measurement
/// recorded as "no-encoder" — a mislabeled cell. A mislabeled cell is worse
/// than no cell: every comparison against it reads "the encoder makes no
/// difference" when it measures nothing of the kind.
///
/// `dispatch()` calls this guard first — before any collect is attempted —
/// so the operator sees the refusal without a subprocess even starting.
/// `RunEnvironment.collect()` and `IdentityEnvironment.collect()` also call
/// it as a belt-and-suspenders check; they abort with exit(1) when it returns
/// a non-nil message. No collect proceeds, no record is written, and the
/// operator sees the refusal on stderr. The guard fires at whichever call
/// comes first; `dispatch()` is always earlier because collect() is reached
/// only after dispatch() routes to a run subcommand.
///
/// When the ablation is implemented (encoder disabled at serve, embedding
/// provider barred, or equivalent), remove this guard and verify the cell
/// measures what it claims. The arm declaration and `defaultArmNames` entry
/// stay — the arm is part of the contract; it is the activation that was
/// missing.
///
/// - Parameter env: Process environment. Production callers pass
///   `ProcessInfo.processInfo.environment` (the default). Tests pass a
///   synthetic dict to avoid mutating the live POSIX env.
/// - Returns: A non-nil refusal message when `MOOT_BENCH_NO_ENCODER=1`; nil
///   otherwise. The message names the switch and describes the missing activation.
///
/// Rust twin: `no_encoder_activation_seam_message()` in arm_register.rs.
public func noEncoderActivationSeamMessage(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    guard env["MOOT_BENCH_NO_ENCODER"] == "1" else { return nil }
    return "[arm-register] MOOT_BENCH_NO_ENCODER=1 is set but the no-encoder"
        + " ablation is not yet implemented. The harness would measure the"
        + " product-default arm and record it as no-encoder — a mislabeled cell."
        + " Unset MOOT_BENCH_NO_ENCODER until the ablation is wired"
        + " (encoder disabled at serve, embedding provider barred, or equivalent)."
}

/// Returns `true` if `subcommand` is exempt from the no-encoder dispatch guard.
///
/// `dispatch()` calls this before invoking `noEncoderActivationSeamMessage()`.
/// Read-only and help subcommands bypass the guard so that `mcp-benchmarker report`
/// and `mcp-benchmarker --help` always work even when `MOOT_BENCH_NO_ENCODER=1`
/// is set. Measuring subcommands are not exempt; the guard fires for them.
///
/// This is the single source of truth for the exempt set in the Swift port.
/// Both `dispatch()` in CLI.swift and tests in BenchmarkRegisterArmTests.swift
/// call this function — there is no second copy of the list.
///
/// Rust twin: `is_no_encoder_dispatch_exempt()` in arm_register.rs.
public func isDispatchExemptFromNoEncoderGuard(_ subcommand: String) -> Bool {
    subcommand == "report"
        || subcommand == "--help" || subcommand == "-h" || subcommand == "help"
}
