// CognitionKitTelemetry.swift
//
// Self-report telemetry constants and emit helpers for CognitionKit.
// Every emit site uses the metric names declared here so names are
// centralised and the Rust test file can reference them by string
// without duplication risk.
//
// IntellectusLib contract (off by default):
//   Intellectus.report(...) is a single atomic load + branch when
//   monitoring is disabled. Zero allocation, no clock, no lock.
//   The autoclosure argument is never evaluated when disabled.
//   Results are byte-identical regardless of monitoring state (C-Det).
//
// Metric inventory (mirrors cognitionkit_telemetry_tests.rs):
//
//   cognitionkit.recipe.run
//     Emitted twice per recipe invocation — once at entry ("start")
//     and once at success exit ("complete"). Tags:
//       recipe    — the recipe's stable name string
//       status    — "start" | "complete"
//       step_count — (complete only) total steps executed
//     Value: 1.0 on start, Double(stepCount) on complete.
//     When monitoring is disabled, the autoclosure is never evaluated.
//
// Callers: GroundedSynthesis.run, MigrationBenchmark.run.
// The ts argument is always caller-supplied epoch seconds (never a
// clock call inside the module — determinism contract holds).

import Foundation
import IntellectusLib

// MARK: - Metric name constants

/// Stable metric names emitted by CognitionKit. String-only so the Rust
/// port can reference them as literals without a foreign-function binding.
public enum CognitionKitMetrics {
    /// Emitted at recipe entry (status "start") and exit (status "complete").
    /// Mirrors `neuronkit.dream.cycle` / `neuronkit.tournament.bt_update`
    /// in the NeuronKit telemetry pattern.
    public static let recipeRun = "cognitionkit.recipe.run"
}

// MARK: - Emit helpers

/// Emit a recipe-start event. The `ts` is caller-supplied epoch seconds;
/// never call a clock here. When monitoring is disabled, zero cost.
///
/// - Parameters:
///   - name: The recipe's stable name string (e.g. "grounded_synthesis").
///   - ts: Caller-supplied epoch seconds (Date().timeIntervalSince1970
///     captured once at the call site, outside the autoclosure).
@inline(__always)
func emitRecipeStart(name: String, ts: Double) {
    // Emit cognitionkit.recipe.run with status "start". The autoclosure
    // wraps the StatSample construction so it is not evaluated when
    // monitoring is disabled (the hot-path off-cost is a single atomic load).
    Intellectus.report(.metric(
        name: CognitionKitMetrics.recipeRun,
        value: 1.0,
        tags: ["recipe": name, "status": "start"],
        ts: ts
    ))
}

/// Emit a recipe-complete event. The `stepCount` is the number of discrete
/// steps the recipe executed (e.g. recalled drawers, benchmarked plans).
/// When monitoring is disabled, zero cost.
///
/// - Parameters:
///   - name: The recipe's stable name string.
///   - stepCount: How many discrete items were processed (drawer count
///     for grounded synthesis; plan count for migration benchmark).
///   - ts: Caller-supplied epoch seconds.
@inline(__always)
func emitRecipeComplete(name: String, stepCount: Int, ts: Double) {
    // Emit cognitionkit.recipe.run with status "complete" and step_count
    // tag so the observer can correlate the pair. The value is the step
    // count as a Double so a metrics dashboard can aggregate it.
    Intellectus.report(.metric(
        name: CognitionKitMetrics.recipeRun,
        value: Double(stepCount),
        tags: [
            "recipe": name,
            "status": "complete",
            "step_count": "\(stepCount)",
        ],
        ts: ts
    ))
}
