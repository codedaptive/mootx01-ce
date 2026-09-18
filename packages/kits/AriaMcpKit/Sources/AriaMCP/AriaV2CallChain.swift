import AriaMCPWire

// MARK: - Module note

/// This file implements `AriaV2CallChain`, the ARIA v2 request-processing
/// chain: three ordered hook sequences that wrap a single v2 tool call.
///
/// The name "CallChain" is deliberate. "Door" is already taken in this kit:
/// it is the recall-strategy selector on `moot_memory_search` (values: rrf /
/// matrixAware / raw / guess), backed by `DoorManifest` and
/// `provisionDoorConfig`, with its own suite
/// `Tests/AriaMCPTests/DoorDispatchTests.swift`. A second unrelated "Door"
/// in the same module would be read as recall-strategy code.

// MARK: - Egress decision

/// The outcome of a gate hook. The return type makes the wrong thing
/// unrepresentable — a transform cannot halt, and a gate cannot silently pass
/// through without a decision.
public enum AriaV2EgressDecision: Sendable {
    /// Gate passed: this result continues to the next egress hook.
    case pass(JSONValue)
    /// Gate fired: this result becomes the final result and no later egress
    /// hook runs.
    case halt(JSONValue)
}

// MARK: - Egress hook kind

/// Two kinds of egress hook. The enum is the only representation — there is
/// no `isGate` boolean.
///
/// - A `transform` hook returns a new result. It cannot halt the chain.
/// - A `gate` hook returns a decision. A `halt` decision ends the chain
///   immediately and returns that payload as the result.
public enum AriaV2EgressHook: Sendable {
    case transform(@Sendable (String, JSONValue, JSONValue?) async throws -> JSONValue)
    case gate(@Sendable (String, JSONValue, JSONValue?) async throws -> AriaV2EgressDecision)
}

// MARK: - Registration

/// One concern's contribution to the chain.
///
/// A concern may declare any combination of transform, ingress, and egress hooks,
/// or none. Each phase has an independent position space: a transform position
/// of 10, an ingress position of 10, and an egress position of 10 are all
/// unrelated. Ordering within each chain is by ascending position; duplicate
/// positions within a chain are rejected at `AriaV2CallChain.init`.
public struct AriaV2ChainRegistration: Sendable {
    public let concernName: String
    /// Transform hook: runs before argument decode so a hook can remove a key
    /// the strict decoder rejects. Returns the mutated arguments.
    public let transform: (position: Int, hook: @Sendable (String, JSONValue) async throws -> JSONValue)?
    /// Ingress (record) hook: runs after decode and after the frozen guard, before
    /// the handler. Returns mutated arguments and optional per-concern state.
    public let ingress: (position: Int, hook: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?))?
    public let egress: (position: Int, hook: AriaV2EgressHook)?

    public init(
        concernName: String,
        transform: (position: Int, hook: @Sendable (String, JSONValue) async throws -> JSONValue)? = nil,
        ingress: (position: Int, hook: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?))? = nil,
        egress: (position: Int, hook: AriaV2EgressHook)? = nil
    ) {
        self.concernName = concernName
        self.transform = transform
        self.ingress = ingress
        self.egress = egress
    }
}

// MARK: - Construction error

/// Errors produced at chain-construction time; none are deferred to run time.
public enum AriaV2CallChainError: Error, Sendable, Equatable {
    case duplicateConcernName(String)
    case duplicateTransformPosition(Int)
    case duplicateIngressPosition(Int)
    case duplicateEgressPosition(Int)
}

// MARK: - Hook failure record

/// A record of a hook error that was contained by the chain.
///
/// The chain contains Swift `throw`s. It does not contain `fatalError` or
/// Objective-C exceptions, which are uncatchable at this level and propagate
/// normally.
public struct AriaV2HookFailure: Sendable {
    public enum Phase: Sendable, Equatable {
        case transform
        case ingress
        case egress
    }
    /// The concern whose hook threw.
    public let concernName: String
    /// Which chain the error occurred in.
    public let phase: Phase
    /// Human-readable description of the error, captured at containment time.
    public let errorDescription: String
}

// MARK: - Halt reason

/// Why (and by whom) the egress chain stopped early, if it did.
public enum AriaV2HaltReason: Sendable, Equatable {
    /// The chain ran to completion with no gate intervention.
    case none
    /// A gate hook returned `.halt`; `concern` names it.
    case gateFired(String)
    /// A gate hook threw; `concern` names it. Fail-closed: the chain halted
    /// even though the gate never produced a decision.
    case gateFailed(String)
}

// MARK: - Outcomes

/// Result of running the transform chain.
public struct AriaV2TransformOutcome: Sendable {
    /// The final arguments after all successful pre-decode mutations.
    public let arguments: JSONValue
    /// Failure records in hook-execution order.
    public let failures: [AriaV2HookFailure]
}

/// Result of running the ingress (record) chain.
public struct AriaV2IngressOutcome: Sendable {
    /// The final arguments after all successful ingress mutations.
    public let arguments: JSONValue
    /// Per-concern state, keyed by concern name. Only present for concerns
    /// whose ingress hook succeeded and returned non-nil state.
    public let state: [String: JSONValue]
    /// Names of concerns whose ingress hook threw.
    public let failedConcerns: Set<String>
    /// Failure records in hook-execution order.
    public let failures: [AriaV2HookFailure]
}

/// Result of running the egress chain.
public struct AriaV2EgressOutcome: Sendable {
    /// The final result after all egress hooks ran (or the chain halted).
    public let result: JSONValue
    /// Whether and why the egress chain was cut short.
    public let halt: AriaV2HaltReason
    /// Failure records in hook-execution order.
    public let failures: [AriaV2HookFailure]
}

// MARK: - Call chain

/// The ARIA v2 pre/post processor.
///
/// Build-once and immutable. Validated at construction, then `Sendable`.
/// The three hook chains run in ascending declared-position order; textual
/// registration order has no effect on behaviour.
///
/// **Transform** runs before argument decode. A hook receives the tool name
/// and the raw arguments, may remove keys (so the strict decoder never sees
/// them), and returns the mutated arguments. The transform phase runs before
/// the frozen-mutation guard; it is for argument shape, not for counting.
///
/// **Ingress** (record phase) runs after decode and after the frozen guard,
/// before the handler. A hook receives the tool name and arguments, may
/// mutate them, and may record state for delivery to its own egress hook.
/// Counting happens here so a refused or decode-failed call is not counted.
///
/// **Egress** runs after the handler returns. A hook receives the tool name,
/// the current result, and any state its own ingress hook recorded.
///
/// **Throw policy** (all four rules, no hook error escapes the chain):
/// 1. An egress transform hook that throws: result unchanged, chain continues, failure recorded.
/// 2. A gate hook that throws: chain halts fail-closed. A guard that cannot decide
///    must not be assumed to permit.
/// 3. An ingress hook that throws: arguments unchanged, no state recorded, that
///    concern's egress hook does not run.
/// 4. If the failed-ingress concern has a gate egress hook: chain halts fail-closed
///    at that egress position (rule 2 applied retroactively).
/// 5. A transform hook that throws: arguments unchanged, chain continues, failure recorded.
///
/// **Scope of containment:** Swift `throw` errors are contained. `fatalError` and
/// Objective-C exceptions are not catchable by this component and propagate normally.
///
/// This component does NOT synthesize a refusal payload on a halt. It halts,
/// returns the payload unmodified, and tells the caller why. The caller renders.
public struct AriaV2CallChain: Sendable {

    // Transform hooks sorted by declared position (ascending).
    private let transformChain: [(concernName: String, hook: @Sendable (String, JSONValue) async throws -> JSONValue)]
    // Ingress hooks sorted by declared position (ascending).
    private let ingressChain: [(concernName: String, hook: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?))]
    // Egress hooks sorted by declared position (ascending).
    private let egressChain: [(concernName: String, hook: AriaV2EgressHook)]
    // Names of concerns whose egress hook is a gate (for fail-closed lookup).
    private let gatingConcerns: Set<String>

    /// Construct the chain from an ordered list of registrations.
    ///
    /// Validation happens here; `runTransform`, `runIngress`, and `runEgress` never throw.
    ///
    /// - Throws: `AriaV2CallChainError.duplicateConcernName` if two registrations
    ///   share a concern name.
    /// - Throws: `AriaV2CallChainError.duplicateTransformPosition` if two transform
    ///   hooks share a declared position.
    /// - Throws: `AriaV2CallChainError.duplicateIngressPosition` if two ingress
    ///   hooks share a declared position.
    /// - Throws: `AriaV2CallChainError.duplicateEgressPosition` if two egress
    ///   hooks share a declared position.
    public init(registrations: [AriaV2ChainRegistration]) throws {
        // 1. Reject duplicate concern names.
        var seenNames = Set<String>()
        for r in registrations {
            guard seenNames.insert(r.concernName).inserted else {
                throw AriaV2CallChainError.duplicateConcernName(r.concernName)
            }
        }

        // 2. Collect and sort transform hooks; reject duplicate positions.
        var transformEntries: [(pos: Int, name: String, hook: @Sendable (String, JSONValue) async throws -> JSONValue)] = []
        var seenTransformPos = Set<Int>()
        for r in registrations {
            guard let (pos, hook) = r.transform else { continue }
            guard seenTransformPos.insert(pos).inserted else {
                throw AriaV2CallChainError.duplicateTransformPosition(pos)
            }
            transformEntries.append((pos, r.concernName, hook))
        }
        transformEntries.sort { $0.pos < $1.pos }

        // 3. Collect and sort ingress hooks; reject duplicate positions.
        var ingressEntries: [(pos: Int, name: String, hook: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?))] = []
        var seenIngressPos = Set<Int>()
        for r in registrations {
            guard let (pos, hook) = r.ingress else { continue }
            guard seenIngressPos.insert(pos).inserted else {
                throw AriaV2CallChainError.duplicateIngressPosition(pos)
            }
            ingressEntries.append((pos, r.concernName, hook))
        }
        ingressEntries.sort { $0.pos < $1.pos }

        // 4. Collect and sort egress hooks; reject duplicate positions.
        var egressEntries: [(pos: Int, name: String, hook: AriaV2EgressHook)] = []
        var seenEgressPos = Set<Int>()
        var gating = Set<String>()
        for r in registrations {
            guard let (pos, hook) = r.egress else { continue }
            guard seenEgressPos.insert(pos).inserted else {
                throw AriaV2CallChainError.duplicateEgressPosition(pos)
            }
            egressEntries.append((pos, r.concernName, hook))
            if case .gate = hook { gating.insert(r.concernName) }
        }
        egressEntries.sort { $0.pos < $1.pos }

        self.transformChain = transformEntries.map { ($0.name, $0.hook) }
        self.ingressChain = ingressEntries.map { ($0.name, $0.hook) }
        self.egressChain = egressEntries.map { ($0.name, $0.hook) }
        self.gatingConcerns = gating
    }

    // MARK: Transform

    /// Run all transform hooks in ascending declared-position order.
    ///
    /// Never throws. Errors from hooks are contained and recorded. The transform
    /// phase runs before argument decode; a hook can remove a key the strict
    /// decoder rejects and the decoder never sees it.
    public func runTransform(toolName: String, arguments: JSONValue) async -> AriaV2TransformOutcome {
        var current = arguments
        var failures: [AriaV2HookFailure] = []

        for (name, hook) in transformChain {
            do {
                current = try await hook(toolName, current)
            } catch {
                failures.append(AriaV2HookFailure(
                    concernName: name,
                    phase: .transform,
                    errorDescription: error.localizedDescription
                ))
                // Arguments unchanged; chain continues.
            }
        }

        return AriaV2TransformOutcome(arguments: current, failures: failures)
    }

    // MARK: Ingress

    /// Run all ingress hooks in ascending declared-position order.
    ///
    /// Never throws. Errors from hooks are contained and recorded. The ingress
    /// phase runs after decode and after the frozen guard; counting happens here
    /// so a refused or decode-failed call is not counted.
    public func runIngress(toolName: String, arguments: JSONValue) async -> AriaV2IngressOutcome {
        var current = arguments
        var state: [String: JSONValue] = [:]
        var failedConcerns = Set<String>()
        var failures: [AriaV2HookFailure] = []

        for (name, hook) in ingressChain {
            do {
                let (newArgs, newState) = try await hook(toolName, current)
                current = newArgs
                if let s = newState { state[name] = s }
            } catch {
                failedConcerns.insert(name)
                failures.append(AriaV2HookFailure(
                    concernName: name,
                    phase: .ingress,
                    errorDescription: error.localizedDescription
                ))
                // Arguments unchanged; no state recorded for this concern.
            }
        }

        return AriaV2IngressOutcome(
            arguments: current,
            state: state,
            failedConcerns: failedConcerns,
            failures: failures
        )
    }

    // MARK: Egress

    /// Run all egress hooks in ascending declared-position order.
    ///
    /// Never throws. Gate errors and fire decisions halt the chain immediately.
    /// Transform errors are contained and the prior result carries forward.
    ///
    /// - Parameters:
    ///   - ingressOutcome: The outcome of the preceding `runIngress` call.
    ///     State from each concern's ingress hook is delivered only to that
    ///     concern's egress hook.
    public func runEgress(
        toolName: String,
        result: JSONValue,
        ingressOutcome: AriaV2IngressOutcome
    ) async -> AriaV2EgressOutcome {
        var current = result
        var failures: [AriaV2HookFailure] = []

        for (name, hook) in egressChain {
            // Rule 3+4: if ingress failed for this concern, apply containment.
            if ingressOutcome.failedConcerns.contains(name) {
                if gatingConcerns.contains(name) {
                    // Rule 4: failed ingress on a gating concern halts fail-closed.
                    return AriaV2EgressOutcome(result: current, halt: .gateFailed(name), failures: failures)
                }
                // Rule 3: non-gating concern — skip its egress hook entirely.
                continue
            }

            let concernState = ingressOutcome.state[name]

            switch hook {
            case .transform(let fn):
                // Rule 1: a transform that throws is contained.
                do {
                    current = try await fn(toolName, current, concernState)
                } catch {
                    failures.append(AriaV2HookFailure(
                        concernName: name,
                        phase: .egress,
                        errorDescription: error.localizedDescription
                    ))
                    // Result unchanged; chain continues.
                }

            case .gate(let fn):
                // Rule 2: a gate that throws halts fail-closed.
                do {
                    switch try await fn(toolName, current, concernState) {
                    case .pass(let newResult):
                        current = newResult
                    case .halt(let haltResult):
                        return AriaV2EgressOutcome(result: haltResult, halt: .gateFired(name), failures: failures)
                    }
                } catch {
                    failures.append(AriaV2HookFailure(
                        concernName: name,
                        phase: .egress,
                        errorDescription: error.localizedDescription
                    ))
                    return AriaV2EgressOutcome(result: current, halt: .gateFailed(name), failures: failures)
                }
            }
        }

        return AriaV2EgressOutcome(result: current, halt: .none, failures: failures)
    }
}
