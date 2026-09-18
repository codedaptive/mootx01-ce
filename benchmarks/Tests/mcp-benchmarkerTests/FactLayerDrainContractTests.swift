import Testing
import Foundation
@testable import mcp_benchmarker

// FactLayerDrainContractTests.swift — enforces the FactLayer "no drain barrier" contract.
//
// moot_file_fact and moot_retire_fact are synchronous structured operations
// that do not enqueue embedding jobs. The FactLayer runner therefore runs
// NO drain barrier. Two tests enforce this:
//
//   1. Source inspection: FactLayerRunner.swift must never contain a call to
//      moot_drain_status. If it does, a drain barrier was added — which implies
//      fact writes now enqueue embedding work. The runner doc-comment carries this
//      constraint: "If the product changes this contract, add a barrier."
//
//   2. Drain-parsing contract: parseDrainResponse correctly identifies both
//      the "no lanes registered" shape and the all-idle/zero-counts shape as
//      non-active, AND correctly identifies non-zero pending/in_flight as active
//      work. This confirms the detection machinery works if a violation ever occurs.
//
// INTERNAL CAPABILITY CELL — outside the fairness-rule comparative lane.
// Twin of the Rust tests added to fact_layer_runner.rs #[cfg(test)].

@Suite("FactLayer drain contract")
struct FactLayerDrainContractTests {

    // MARK: - Source contract

    /// Verifies that FactLayerRunner.swift never calls moot_drain_status.
    ///
    /// moot_file_fact and moot_retire_fact are synchronous structured operations
    /// that do not enqueue embedding jobs, so the encode-drain cycle that guards
    /// the memory lane does not apply to the fact-layer runner. If this test
    /// fails, a drain barrier was added to the runner, which implies fact writes
    /// now enqueue encode work. In that case: add `waitForEncodeDrain` to
    /// `runFactLayerCell`, update the runner's doc-comment, and remove this
    /// assertion.
    @Test("FactLayerRunner source never calls moot_drain_status")
    func factLayerRunnerSourceNeverCallsDrainStatus() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()   // mcp-benchmarkerTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/mcp-benchmarker/FactLayerRunner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // moot_drain_status must be absent from the runner source. Its presence
        // means a drain barrier was introduced — both the runner doc-comment and
        // this assertion must then be updated to reflect the new contract.
        #expect(
            !source.contains("moot_drain_status"),
            "FactLayerRunner.swift must not call moot_drain_status — moot_file_fact and moot_retire_fact are synchronous structured operations that do not enqueue embedding jobs. Add a drain barrier to runFactLayerCell and remove this assertion if the product changes this contract."
        )
    }

    // MARK: - Drain-parsing contract

    /// Verifies that parseDrainResponse correctly identifies both empty-queue
    /// shapes as non-active, and correctly identifies non-zero counts as active.
    ///
    /// These are the only drain-status shapes relevant to the FactLayer contract:
    ///
    /// - "drains: none" — no encode lane registered. Expected on a fresh estate
    ///   where fact writes have been issued and no embedding was ever enqueued.
    ///   Parses as .noLanes — no work outstanding.
    ///
    /// - All lanes idle with pending==0 and inFlight==0 — no encode work
    ///   outstanding. Expected when a corpus lane is registered but fact writes
    ///   produced no embedding jobs. Parses as .idle — no work outstanding.
    ///
    /// - pending>0 or inFlight>0 — encode work outstanding. This is what the
    ///   parser returns if fact writes HAD enqueued embedding jobs. NEVER expected
    ///   after moot_file_fact or moot_retire_fact. Verified here to confirm the
    ///   parser CAN detect a contract violation; it must never be the actual result.
    @Test("drain response after fact writes parses as idle or noLanes, not draining")
    func drainResponseAfterFactWritesIsNotDraining() {
        // Shape A: no encode lane registered. Correct outcome on an estate where
        // fact writes have been issued and no embedding was ever enqueued.
        #expect(parseDrainResponse("drains: none") == .noLanes)

        // Shape B, all-idle: corpus lane registered, zero pending, zero in_flight.
        // Correct when no fact-write encode jobs were ever queued.
        let allIdle = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0"
        #expect(parseDrainResponse(allIdle) == .idle)

        // Non-zero pending: encode work outstanding. This result means fact writes
        // enqueued embedding jobs — a contract violation. Verified here so the
        // detection path is confirmed to work before a live regression could occur.
        let pendingWork = "drains: 1\n  corpus_encode: draining \u{2014} pending: 1, in_flight: 0"
        #expect(parseDrainResponse(pendingWork) == .draining)

        // Non-zero in_flight: encode work in progress. Same contract violation.
        let inFlightWork = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 1"
        #expect(parseDrainResponse(inFlightWork) == .draining)
    }
}
