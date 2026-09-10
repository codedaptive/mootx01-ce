import Foundation
import Testing
@testable import AriaMCP
import AriaMCPWire

// MARK: - Test helpers

/// A deterministic error used by test doubles. Carries a label so assertions can
/// verify which hook produced which failure.
private struct TestHookError: Error {
    let label: String
}

/// Append `marker` to a result that is a `.string`. Returns the modified value.
/// Used by transform doubles to prove they ran and to track order.
private func appendMarker(_ marker: String) -> @Sendable (String, JSONValue, JSONValue?) async throws -> JSONValue {
    { _, result, _ in
        guard case .string(let s) = result else { return result }
        return .string(s + marker)
    }
}

// MARK: - Suite

@Suite("ARIA v2 call chain")
struct AriaV2CallChainTests {

    // MARK: 1

    @Test func emptyChainReturnsArgumentsAndResultUnchanged() async throws {
        let chain = try AriaV2CallChain(registrations: [])
        let args: JSONValue = .object(["query": .string("x")])
        let result: JSONValue = .string("original")

        let ingress = await chain.runIngress(toolName: "moot_memory_search", arguments: args)
        let egress = await chain.runEgress(
            toolName: "moot_memory_search",
            result: result,
            ingressOutcome: ingress
        )

        #expect(ingress.arguments == args)
        #expect(egress.result == result)
        #expect(egress.halt == .none)
        #expect(egress.failures.isEmpty)
        #expect(ingress.failures.isEmpty)
    }

    // MARK: 2

    @Test func ingressStripsKeyAndTheDecoderNeverSeesIt() async throws {
        let rawArgs: JSONValue = .object(["query": .string("x"), "echo_query": .bool(true)])

        // Half 1: decode without the chain — must fail, error must name echo_query.
        do {
            _ = try AriaV2ArgumentDecoder(rawArgs, allowedKeys: ["query"])
            #expect(Bool(false), "AriaV2ArgumentDecoder should have thrown for echo_query")
        } catch let err as JSONRPCError {
            // The invalid-argument data object carries "path": "echo_query".
            if let dataValue = err.data,
               case .object(let dict) = dataValue,
               let pathValue = dict["path"],
               case .string(let path) = pathValue {
                #expect(path == "echo_query")
            } else {
                #expect(Bool(false), "JSONRPCError.data did not carry expected path field")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type thrown by AriaV2ArgumentDecoder: \(error)")
        }

        // Half 2: run ingress that strips echo_query, then decode — must succeed.
        let chain = try AriaV2CallChain(registrations: [
            AriaV2ChainRegistration(
                concernName: "echo-query-stripper",
                ingress: (
                    position: 10,
                    hook: { _, args in
                        guard case .object(var dict) = args else { return (args, nil) }
                        dict.removeValue(forKey: "echo_query")
                        return (.object(dict), nil)
                    }
                )
            )
        ])

        let outcome = await chain.runIngress(toolName: "moot_memory_search", arguments: rawArgs)
        // The stripped arguments must decode cleanly with only "query" allowed.
        let decoder = try AriaV2ArgumentDecoder(outcome.arguments, allowedKeys: ["query"])
        // If we reach this line, decode succeeded. Verify the retained key is there.
        #expect(decoder.arguments["query"] == .string("x"))
    }

    // MARK: 3

    @Test func ingressStateReachesItsOwnEgressHookExactly() async throws {
        let sentinelState: JSONValue = .string("distinctive-sentinel-abc123")

        let chain = try AriaV2CallChain(registrations: [
            AriaV2ChainRegistration(
                concernName: "state-carrier",
                ingress: (
                    position: 10,
                    hook: { _, args in (args, sentinelState) }
                ),
                egress: (
                    position: 10,
                    hook: .transform({ _, result, state in
                        // Signal whether we received exactly the sentinel.
                        if state == sentinelState {
                            return .string("state-matched")
                        } else {
                            return .string("state-mismatch")
                        }
                    })
                )
            )
        ])

        let ingress = await chain.runIngress(
            toolName: "moot_memory_search",
            arguments: .object(["q": .string("y")])
        )
        let egress = await chain.runEgress(
            toolName: "moot_memory_search",
            result: .string("base"),
            ingressOutcome: ingress
        )

        #expect(egress.result == .string("state-matched"))
        #expect(egress.halt == .none)
        #expect(egress.failures.isEmpty)
    }

    // MARK: 4

    @Test func stateIsDeliveredOnlyToItsOwnConcern() async throws {
        let alphaState: JSONValue = .string("alpha-tag")
        let betaState: JSONValue = .string("beta-tag")

        let chain = try AriaV2CallChain(registrations: [
            AriaV2ChainRegistration(
                concernName: "alpha",
                ingress: (position: 10, hook: { _, args in (args, alphaState) }),
                egress: (position: 10, hook: .transform({ _, result, state in
                    guard case .string(let s) = result else { return result }
                    // Explicitly verify beta's tag is absent.
                    if state == .some(betaState) {
                        return .string(s + "|alpha-received-beta-state")
                    }
                    if state == .some(alphaState) {
                        return .string(s + "|alpha-ok")
                    }
                    return .string(s + "|alpha-wrong-state")
                }))
            ),
            AriaV2ChainRegistration(
                concernName: "beta",
                ingress: (position: 20, hook: { _, args in (args, betaState) }),
                egress: (position: 20, hook: .transform({ _, result, state in
                    guard case .string(let s) = result else { return result }
                    // Explicitly verify alpha's tag is absent.
                    if state == .some(alphaState) {
                        return .string(s + "|beta-received-alpha-state")
                    }
                    if state == .some(betaState) {
                        return .string(s + "|beta-ok")
                    }
                    return .string(s + "|beta-wrong-state")
                }))
            )
        ])

        let ingress = await chain.runIngress(
            toolName: "moot_memory_search",
            arguments: .object(["q": .string("y")])
        )
        let egress = await chain.runEgress(
            toolName: "moot_memory_search",
            result: .string("base"),
            ingressOutcome: ingress
        )

        #expect(egress.result == .string("base|alpha-ok|beta-ok"))
        #expect(egress.halt == .none)
        #expect(egress.failures.isEmpty)
    }

    // MARK: 5

    @Test func egressHooksRunInDeclaredOrderNotTextualOrder() async throws {
        // Part A: register concern "hi" (position 20) before concern "lo" (position 10)
        // in textual order. Assert declared order wins: "lo" marker appears before "hi".
        let chainA = try AriaV2CallChain(registrations: [
            // Textually first, declared position 20 — should run SECOND.
            AriaV2ChainRegistration(
                concernName: "hi",
                egress: (position: 20, hook: .transform(appendMarker("|hi")))
            ),
            // Textually second, declared position 10 — should run FIRST.
            AriaV2ChainRegistration(
                concernName: "lo",
                egress: (position: 10, hook: .transform(appendMarker("|lo")))
            )
        ])

        let ingressA = await chainA.runIngress(toolName: "t", arguments: .object([:]))
        let egressA = await chainA.runEgress(toolName: "t", result: .string("base"), ingressOutcome: ingressA)
        // lo runs first (position 10), hi runs second (position 20).
        #expect(egressA.result == .string("base|lo|hi"))

        // Part B: same concerns, positions swapped. Textual order is now "lo" before "hi",
        // but "hi" has the lower position — so "hi" should run first now.
        let chainB = try AriaV2CallChain(registrations: [
            // Textually first, declared position 10 — should run FIRST.
            AriaV2ChainRegistration(
                concernName: "lo",
                egress: (position: 10, hook: .transform(appendMarker("|lo")))
            ),
            // Textually second, declared position 20 — should run SECOND.
            AriaV2ChainRegistration(
                concernName: "hi",
                egress: (position: 20, hook: .transform(appendMarker("|hi")))
            )
        ])

        let ingressB = await chainB.runIngress(toolName: "t", arguments: .object([:]))
        let egressB = await chainB.runEgress(toolName: "t", result: .string("base"), ingressOutcome: ingressB)
        // lo has position 10, hi has position 20 — same order as A.
        #expect(egressB.result == .string("base|lo|hi"))

        // Part C: chainB registrations in same textual order but swap the positions,
        // so now "lo" is at 20 and "hi" is at 10. Order should flip to hi-then-lo.
        let chainC = try AriaV2CallChain(registrations: [
            // Textually first, declared position 20 — should run SECOND.
            AriaV2ChainRegistration(
                concernName: "lo",
                egress: (position: 20, hook: .transform(appendMarker("|lo")))
            ),
            // Textually second, declared position 10 — should run FIRST.
            AriaV2ChainRegistration(
                concernName: "hi",
                egress: (position: 10, hook: .transform(appendMarker("|hi")))
            )
        ])

        let ingressC = await chainC.runIngress(toolName: "t", arguments: .object([:]))
        let egressC = await chainC.runEgress(toolName: "t", result: .string("base"), ingressOutcome: ingressC)
        // hi has position 10, lo has position 20 — flipped.
        #expect(egressC.result == .string("base|hi|lo"))
    }

    // MARK: 6

    @Test func aFiringGateSkipsEveryLaterEgressHook() async throws {
        let chain = try AriaV2CallChain(registrations: [
            // Gate at position 10 — fires.
            AriaV2ChainRegistration(
                concernName: "guard",
                egress: (position: 10, hook: .gate({ _, result, _ in
                    .halt(.string("halted-by-guard"))
                }))
            ),
            // Transform at position 20 — must NOT run after the gate fires.
            AriaV2ChainRegistration(
                concernName: "late-marker",
                egress: (position: 20, hook: .transform(appendMarker("|late")))
            )
        ])

        let ingress = await chain.runIngress(toolName: "t", arguments: .object([:]))
        let egress = await chain.runEgress(
            toolName: "t",
            result: .string("base"),
            ingressOutcome: ingress
        )

        // The gate fired — result is the halted payload, late marker must be absent.
        #expect(egress.result == .string("halted-by-guard"))
        #expect(egress.halt == .gateFired("guard"))
        if case .string(let s) = egress.result {
            #expect(!s.contains("|late"))
        }
        #expect(egress.failures.isEmpty)
    }

    // MARK: 7

    @Test func aPassingGateLetsTheChainComplete() async throws {
        let chain = try AriaV2CallChain(registrations: [
            // Gate at position 10 — passes.
            AriaV2ChainRegistration(
                concernName: "permissive-guard",
                egress: (position: 10, hook: .gate({ _, result, _ in
                    .pass(result)
                }))
            ),
            // Transform at position 20 — must run.
            AriaV2ChainRegistration(
                concernName: "late-marker",
                egress: (position: 20, hook: .transform(appendMarker("|late")))
            )
        ])

        let ingress = await chain.runIngress(toolName: "t", arguments: .object([:]))
        let egress = await chain.runEgress(
            toolName: "t",
            result: .string("base"),
            ingressOutcome: ingress
        )

        #expect(egress.result == .string("base|late"))
        #expect(egress.halt == .none)
        #expect(egress.failures.isEmpty)
    }

    // MARK: 8

    @Test func aFailingTransformIsContainedAndTheChainContinues() async throws {
        let chain = try AriaV2CallChain(registrations: [
            // Transform at position 10 — throws; must not append its marker.
            AriaV2ChainRegistration(
                concernName: "failing-transform",
                egress: (position: 10, hook: .transform({ _, _, _ in
                    throw TestHookError(label: "transform-intentional")
                }))
            ),
            // Transform at position 20 — must still run after the error.
            AriaV2ChainRegistration(
                concernName: "surviving-marker",
                egress: (position: 20, hook: .transform(appendMarker("|survived")))
            )
        ])

        let ingress = await chain.runIngress(toolName: "t", arguments: .object([:]))
        let egress = await chain.runEgress(
            toolName: "t",
            result: .string("base"),
            ingressOutcome: ingress
        )

        // Failing transform's output is discarded — its marker is absent.
        // Surviving transform ran — its marker is present.
        #expect(egress.result == .string("base|survived"))
        #expect(egress.halt == .none)
        // Exactly one failure recorded, naming the failing concern and egress phase.
        #expect(egress.failures.count == 1)
        #expect(egress.failures[0].concernName == "failing-transform")
        #expect(egress.failures[0].phase == .egress)
    }

    // MARK: 9

    @Test func aFailingGateHaltsTheChainFailClosed() async throws {
        let chain = try AriaV2CallChain(registrations: [
            // Gate at position 10 — throws.
            AriaV2ChainRegistration(
                concernName: "erroring-gate",
                egress: (position: 10, hook: .gate({ _, _, _ in
                    throw TestHookError(label: "gate-intentional")
                }))
            ),
            // Transform at position 20 — must NOT run after the gate error.
            AriaV2ChainRegistration(
                concernName: "late-marker",
                egress: (position: 20, hook: .transform(appendMarker("|late")))
            )
        ])

        let ingress = await chain.runIngress(toolName: "t", arguments: .object([:]))
        let egress = await chain.runEgress(
            toolName: "t",
            result: .string("base"),
            ingressOutcome: ingress
        )

        // Gate error halts fail-closed — late marker must be absent.
        #expect(egress.halt == .gateFailed("erroring-gate"))
        if case .string(let s) = egress.result {
            #expect(!s.contains("|late"))
        }
        // Failure recorded.
        #expect(egress.failures.count == 1)
        #expect(egress.failures[0].concernName == "erroring-gate")
        #expect(egress.failures[0].phase == .egress)
    }

    // MARK: 10

    @Test func aFailingIngressHookDiscardsItsMutationAndSkipsItsEgressPartner() async throws {
        let chain = try AriaV2CallChain(registrations: [
            // Concern whose ingress throws — mutation must be discarded, egress must not run.
            AriaV2ChainRegistration(
                concernName: "failing-ingress",
                ingress: (position: 10, hook: { _, _ in
                    throw TestHookError(label: "ingress-intentional")
                }),
                egress: (position: 10, hook: .transform(appendMarker("|failing-egress-ran")))
            ),
            // A second concern whose ingress mutates args and egress appends a marker.
            AriaV2ChainRegistration(
                concernName: "healthy",
                ingress: (position: 20, hook: { _, args in
                    guard case .object(var d) = args else { return (args, nil) }
                    d["healthy-key"] = .bool(true)
                    return (.object(d), .string("healthy-state"))
                }),
                egress: (position: 20, hook: .transform(appendMarker("|healthy-ran")))
            )
        ])

        let args: JSONValue = .object(["original": .string("yes")])
        let ingress = await chain.runIngress(toolName: "t", arguments: args)

        // Failing ingress: args unchanged (no "mutated" key), no state recorded.
        if case .object(let d) = ingress.arguments {
            #expect(d["original"] == .string("yes"))
        }
        #expect(ingress.state["failing-ingress"] == nil)
        // Healthy ingress: mutation present, state recorded.
        if case .object(let d) = ingress.arguments {
            #expect(d["healthy-key"] == .bool(true))
        }
        #expect(ingress.state["healthy"] == .some(.string("healthy-state")))
        // Ingress failure recorded.
        #expect(ingress.failures.count == 1)
        #expect(ingress.failures[0].concernName == "failing-ingress")
        #expect(ingress.failures[0].phase == .ingress)

        let egress = await chain.runEgress(
            toolName: "t",
            result: .string("base"),
            ingressOutcome: ingress
        )

        // Failing concern's egress must not have run — its marker is absent.
        if case .string(let s) = egress.result {
            #expect(!s.contains("|failing-egress-ran"))
        }
        // Healthy concern's egress ran.
        #expect(egress.result == .string("base|healthy-ran"))
        #expect(egress.halt == .none)
        #expect(egress.failures.isEmpty)
    }

    // MARK: 11

    @Test func aFailingIngressHookOfAGatingConcernHaltsFailClosed() async throws {
        let chain = try AriaV2CallChain(registrations: [
            // Gating concern whose ingress throws.
            AriaV2ChainRegistration(
                concernName: "lost-gate",
                ingress: (position: 10, hook: { _, _ in
                    throw TestHookError(label: "gate-ingress-intentional")
                }),
                egress: (position: 10, hook: .gate({ _, result, _ in .pass(result) }))
            ),
            // Later transform — must NOT run because the gate's ingress failed.
            AriaV2ChainRegistration(
                concernName: "after-gate",
                egress: (position: 20, hook: .transform(appendMarker("|after-gate-ran")))
            )
        ])

        let ingress = await chain.runIngress(toolName: "t", arguments: .object([:]))
        let egress = await chain.runEgress(
            toolName: "t",
            result: .string("base"),
            ingressOutcome: ingress
        )

        // Rule 4: failed ingress on a gating concern halts fail-closed.
        #expect(egress.halt == .gateFailed("lost-gate"))
        if case .string(let s) = egress.result {
            #expect(!s.contains("|after-gate-ran"))
        }
    }

    // MARK: 12

    @Test func duplicateConcernNamesAreRejectedAtRegistration() throws {
        #expect(
            throws: AriaV2CallChainError.duplicateConcernName("shared-name"),
            "Expected duplicateConcernName error"
        ) {
            try AriaV2CallChain(registrations: [
                AriaV2ChainRegistration(concernName: "shared-name"),
                AriaV2ChainRegistration(concernName: "shared-name")
            ])
        }
    }

    // MARK: 13

    @Test func duplicateIngressPositionsAreRejectedAtRegistration() throws {
        #expect(
            throws: AriaV2CallChainError.duplicateIngressPosition(10),
            "Expected duplicateIngressPosition error"
        ) {
            try AriaV2CallChain(registrations: [
                AriaV2ChainRegistration(
                    concernName: "concern-a",
                    ingress: (position: 10, hook: { _, args in (args, nil) })
                ),
                AriaV2ChainRegistration(
                    concernName: "concern-b",
                    ingress: (position: 10, hook: { _, args in (args, nil) })
                )
            ])
        }
    }

    // MARK: 14

    @Test func duplicateEgressPositionsAreRejectedAtRegistration() throws {
        #expect(
            throws: AriaV2CallChainError.duplicateEgressPosition(10),
            "Expected duplicateEgressPosition error"
        ) {
            try AriaV2CallChain(registrations: [
                AriaV2ChainRegistration(
                    concernName: "concern-a",
                    egress: (position: 10, hook: .transform({ _, r, _ in r }))
                ),
                AriaV2ChainRegistration(
                    concernName: "concern-b",
                    egress: (position: 10, hook: .transform({ _, r, _ in r }))
                )
            ])
        }
    }
}
