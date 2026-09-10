import AriaMCPWire

// MARK: - Position constants

/// Position namespace for the ARIA v2 call chain.
///
/// Ingress and egress positions are independent ordinals: an ingress position
/// of 10 and an egress position of 10 are unrelated.
enum AriaV2ChainPositions {

    // MARK: Ingress

    /// Session-accounting concern (recordCall) runs at ingress position 10.
    ///
    /// Position 10 places accounting after the frozen-mutation guard and after
    /// argument decode. The session counter must not advance on a frozen-mutation
    /// refusal or on a malformed-arguments decode failure, so the ingress chain
    /// runs AFTER both guards — never before them.
    static let ingressCoaching: Int = 10

    // MARK: Egress

    /// Egress position 1 is the exit-gate slot, reserved for HammerGuard.
    ///
    /// Nothing registers here in this mission. The GATE 1 test proves the slot
    /// semantics: a gate registered at position 1 alongside the production
    /// registrations runs before coaching and, when it fires, coaching never
    /// runs.
    static let egressGateReserved: Int = 1

    /// Coaching hint and periodic-block transform run at egress position 10.
    static let egressCoaching: Int = 10
}

// MARK: - Production registration factory

/// Build the production chain registrations for one v2 call.
///
/// Called per call because coaching's egress hook captures the decoded request
/// and the session state, both of which vary per call.
///
/// Construction can only fail on a duplicate concern name or a duplicate
/// position, both programmer errors in this hard-coded list. Use `try!` at
/// the call site (precedent: ToolDispatch.swift `try! AriaV2CapabilityDigest.digest`).
///
/// - Parameters:
///   - request: The decoded `AriaSurfaceRequest` for this call.
///   - modeSessionState: The per-session state actor.
/// - Returns: One registration, concern name `"coaching"`.
func ariaV2ProductionRegistrations(
    request: AriaSurfaceRequest,
    modeSessionState: ModeSessionState
) -> [AriaV2ChainRegistration] {

    // MARK: Coaching ingress hook

    // Calls `recordCall` so the periodic-coaching counter advances exactly
    // where it does today: after the frozen-mutation guard and after argument
    // decode, immediately before execute.
    //
    // The ingress chain runs AFTER argument decode in this adoption. The
    // arguments the hook returns are not consumed at this call site because
    // the decoder has already run. The raw arguments are forwarded in any case
    // so the hook receives a well-formed value and the contract is satisfied.
    // No concern registered at this position may mutate arguments.
    let coachingIngress: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?) = {
        toolName, arguments in
        await modeSessionState.recordCall(toolName: toolName, mode: nil)
        return (arguments, nil)
    }

    // MARK: Coaching egress hook (transform — not a gate)

    // Order preserved from the inline implementation that this hook replaces:
    //   1. Hint injection: AriaV2Coach.coachingHint → AriaV2Envelope.applyHint.
    //      Suppressed on error results by AriaV2Coach (RULING 3, §12.5).
    //   2. Periodic block: shouldCoach → snapshot → PeriodicCoach.renderBlock
    //      → AriaV2Envelope.applyCoachingBlock.
    //      Applied to all results including error results — existing behaviour
    //      preserved unchanged.
    //
    // `failures` on the egress outcome is not consumed: no concern registered
    // today can throw. A contained error leaves the result unchanged; the chain
    // continues. No logging mechanism is invented here.
    let coachingEgress = AriaV2EgressHook.transform({ [request] _, result, _ in
        var r = result
        if let hint = AriaV2Coach.coachingHint(request: request, result: r) {
            r = AriaV2Envelope.applyHint(hint, to: r)
        }
        if await modeSessionState.shouldCoach() {
            let snap = await modeSessionState.snapshot
            r = AriaV2Envelope.applyCoachingBlock(PeriodicCoach.renderBlock(for: snap), to: r)
        }
        return r
    })

    return [
        AriaV2ChainRegistration(
            concernName: "coaching",
            ingress: (position: AriaV2ChainPositions.ingressCoaching, hook: coachingIngress),
            egress: (position: AriaV2ChainPositions.egressCoaching, hook: coachingEgress)
        )
    ]
}
