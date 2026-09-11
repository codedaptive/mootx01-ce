import Foundation
import CognitionKit
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP
import AriaMCPWire

private extension JSONValue {
    /// Return the text content from a textResult object (first text item).
    var firstTextContent: String? {
        guard case .object(let obj) = self,
              case .array(let content) = obj["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return nil }
        return text
    }
}

/// Adoption tests for the AriaV2CallChain wiring in ToolDispatch.
///
/// Each gate discriminates a specific aspect of the adoption:
///
/// GATE 1 — slot reservation: egress position 1 is unoccupied in the
///           production registrations. The discriminating assertions are the
///           position checks; the test fails when egressCoaching is set to 1.
///
/// GATE 2 — ingress placement: a frozen-estate v2 mutation refusal leaves the
///           session call counter at zero; a malformed-argument call also
///           leaves the counter at zero. These tests fail when the ingress
///           invocation is moved above the frozen guard or above decode, not
///           against the pre-adoption baseline.
///
/// GATE 3 — golden fixture untouched (proved via git diff --stat, not tested
///           here; see report).
///
/// GATE 4 — live binary smoke test (external invocation; see report).
///
/// GATE 5 — egress wiring: the coaching block appears at call 25 and not
///           before. This test fails if the egress chain invocation is removed
///           from dispatchV2.
@Suite("AriaV2ChainAdoptionTests")
struct AriaV2ChainAdoptionTests {

    // MARK: - Helpers

    private static let pinnedEnvironment = [
        BenchClock.envKey: "2026-09-08T00:00:00Z",
    ]

    private func makeDispatcher(
        frozen: Bool = false,
        environment: [String: String] = [:]
    ) async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-chain-adoption-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (
            ToolDispatcher(
                kit: kit,
                handle: handle,
                environment: Self.pinnedEnvironment.merging(environment) { _, override in override },
                posture: frozen ? .frozen : .live),
            kit,
            handle)
    }

    // MARK: - GATE 1: Slot reservation

    /// The production factory leaves egress position 1 (the reserved exit-gate
    /// slot) unoccupied. The discriminating assertions are the position checks:
    /// if AriaV2ChainPositions.egressCoaching is set to 1, the occupancy check
    /// fails because coaching would then occupy the reserved slot, and adding a
    /// gate there would cause chain construction to throw duplicateEgressPosition.
    ///
    /// The halt assertions are retained because they cost nothing, but this is a
    /// slot-reservation gate, not an ordering gate — it does not prove coaching
    /// did not run.
    @Test func gate1ProductionRegistrationsLeaveEgressSlot1Unoccupied() async throws {
        let session = ModeSessionState()
        // Provide a minimal v2 request — moot_monitoring_status is an inspection
        // so it decodes cleanly and has no mutation side effects.
        let request = AriaSurfaceRequest.monitoringStatus(
            try AriaV2MonitoringInspection.Request(arguments: [:]))

        let production = ariaV2ProductionRegistrations(request: request, modeSessionState: session)

        // Verify coaching's egress position is strictly greater than 1.
        let coachingReg = try #require(production.first { $0.concernName == "coaching" })
        let coachingEgressPos = try #require(coachingReg.egress?.position)
        #expect(coachingEgressPos > AriaV2ChainPositions.egressGateReserved,
            "coaching egress position \(coachingEgressPos) must be > reserved slot 1")

        // Verify position 1 is not occupied by any production registration.
        let occupiesReservedSlot = production.contains { reg in
            reg.egress?.position == AriaV2ChainPositions.egressGateReserved
        }
        #expect(!occupiesReservedSlot, "egress position 1 must be unoccupied in production registrations")

        // Gate double at position 1: fires immediately with a distinct sentinel.
        // This exercises the halt mechanics at the reserved slot:
        //   (a) egressOutcome.halt is .gateFired("test-gate")
        //   (b) egressOutcome.result is the gate's exact sentinel payload
        let sentinelPayload: JSONValue = .string("gate-halt-sentinel")
        let gateDouble = AriaV2ChainRegistration(
            concernName: "test-gate",
            ingress: nil,
            egress: (
                position: AriaV2ChainPositions.egressGateReserved,
                hook: .gate({ _, _, _ in .halt(sentinelPayload) })
            )
        )

        let chain = try AriaV2CallChain(registrations: production + [gateDouble])

        // Run ingress (coaching's ingress hook calls recordCall on the session).
        let dummyArgs: JSONValue = .object([:])
        let ingressOutcome = await chain.runIngress(toolName: "moot_monitoring_status", arguments: dummyArgs)

        // Run egress with a non-error result.
        let dummyResult: JSONValue = .string("original")
        let egressOutcome = await chain.runEgress(
            toolName: "moot_monitoring_status",
            result: dummyResult,
            ingressOutcome: ingressOutcome
        )

        // The chain must have halted at the gate, not run to completion.
        guard case .gateFired(let haltingConcern) = egressOutcome.halt else {
            Issue.record("expected .gateFired halt reason, got \(egressOutcome.halt)")
            return
        }
        #expect(haltingConcern == "test-gate",
            "gate at position 1 must be the halting concern, got \(haltingConcern)")

        // Result must be exactly the gate's sentinel — not further modified.
        #expect(egressOutcome.result == sentinelPayload,
            "egress result must be the gate's halt payload, got \(egressOutcome.result)")
    }

    // MARK: - GATE 2: Ingress placement

    /// A frozen-estate v2 MUTATION refusal returns before the ingress chain
    /// runs. The session call counter must remain at zero.
    ///
    /// This test fails if the ingress chain is moved above the frozen guard
    /// in dispatchV2 (the counter would advance to 1 on the refused call).
    @Test func gate2FrozenV2MutationRefusalLeavesSessionCounterAtZero() async throws {
        let (frozen, kit, handle) = try await makeDispatcher(frozen: true)
        defer { Task { try? await kit.close(handle) } }

        // moot_file_memory is a mutation — refused on a frozen estate.
        let result = try await frozen.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("must not land"),
                "subject": .string("gate2-frozen-test"),
                "location": .string("gate2"),
            ]))

        // Verify the call was refused.
        #expect(result.objectValue?["isError"] == .bool(true))
        #expect(
            result.objectValue?["structuredContent"]?.objectValue?["error"]?
                .objectValue?["code"] == .string("estate_frozen"))

        // The session counter must be zero: the frozen guard returned before
        // the ingress hook could call recordCall.
        let snap = await frozen.modeSessionState.snapshot
        #expect(snap.totalCalls == 0,
            "frozen v2 mutation refusal must not advance the session counter; got \(snap.totalCalls)")
    }

    /// A malformed-argument call on a live v2 name rejects at decode time,
    /// before dispatchV2 is reached. The session call counter must remain at zero.
    ///
    /// This test fails if the ingress chain were moved above the decode step
    /// (the counter would advance before the decode error is returned).
    @Test func gate2MalformedArgumentsLeaveSessionCounterAtZero() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // moot_file_memory requires `subject`; omitting it produces invalidParams.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object(["content": .string("no subject provided")]))
            Issue.record("malformed moot_file_memory should have thrown invalidParams")
        } catch let err as JSONRPCError {
            #expect(err.code == JSONRPCErrorCode.invalidParams)
        }

        let snap = await dispatcher.modeSessionState.snapshot
        #expect(snap.totalCalls == 0,
            "malformed-argument decode failure must not advance the session counter; got \(snap.totalCalls)")
    }

    // MARK: - GATE 5: Egress wiring

    /// The egress chain is wired into the live dispatcher: calls 1 to 24
    /// produce no coaching block; call 25 produces "[Moot coaching".
    ///
    /// This test fails if the chain.runEgress call is removed from dispatchV2
    /// and coreResult is returned directly in its place.
    @Test func gate5EgressWiringCoachingBlockAppearsAtCall25() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Calls 1–24: no coaching block.
        for n in 1...24 {
            let result = try await dispatcher.dispatch(
                name: "moot_monitoring_status",
                arguments: .object([:])
            )
            let text = result.firstTextContent ?? ""
            #expect(!text.contains("[Moot coaching"),
                "call \(n): coaching block must not appear before call 25")
        }

        // Call 25: coaching block fires.
        let result25 = try await dispatcher.dispatch(
            name: "moot_monitoring_status",
            arguments: .object([:])
        )
        let text25 = result25.firstTextContent ?? ""
        #expect(text25.contains("[Moot coaching"),
            "call 25: coaching block must appear at the default cadence of 25 calls")
    }
}
