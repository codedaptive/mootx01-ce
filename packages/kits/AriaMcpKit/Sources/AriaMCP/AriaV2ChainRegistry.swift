import AriaMCPWire

// MARK: - Position constants

/// Position namespace for the ARIA v2 call chain.
///
/// Transform, ingress, and egress positions are independent ordinals: a
/// transform position of 10, an ingress position of 10, and an egress position
/// of 10 are all unrelated. Position 1 on the egress chain is the exit-gate
/// slot, reserved for HammerGuard. The GATE 1 test proves the slot semantics.
enum AriaV2ChainPositions {

    // MARK: Transform

    /// Transform position 1 is reserved for pre-decode argument mutation.
    ///
    /// The transform phase runs before AriaSurfaceDecoder so a hook can remove
    /// a key the strict decoder rejects. No concern registers on the transform
    /// phase in production today; the slot is defined so future concerns can
    /// reserve a position without colliding.
    static let transformReserved: Int = 1

    // MARK: Ingress (record phase)

    /// Session-accounting concern (recordCall) runs at ingress position 10.
    ///
    /// The ingress (record) phase runs after decode and after the frozen-mutation
    /// guard. Counting runs here because a refused or decode-failed call is not
    /// a call. The transform phase runs before decode and must not advance the
    /// counter.
    static let ingressCoaching: Int = 10

    // MARK: Egress

    /// Egress position 1 is the exit-gate slot, reserved for HammerGuard.
    ///
    /// Nothing registers here in production today. The GATE 1 test proves the
    /// slot semantics: a gate at position 1 alongside the production
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
/// The transform phase is empty in production: no concern removes keys before
/// decode. The chain's transform slot is defined and reserved; it lands empty.
///
/// - Parameters:
///   - request: The decoded `AriaSurfaceRequest` for this call.
///   - modeSessionState: The per-session state actor.
/// - Returns: One registration, concern name `"coaching"`.
func ariaV2ProductionRegistrations(
    request: AriaSurfaceRequest,
    modeSessionState: ModeSessionState
) -> [AriaV2ChainRegistration] {

    // MARK: Coaching ingress (record) hook

    // Calls `recordCall` after decode and after the frozen guard so the
    // periodic-coaching counter advances on admitted calls only. A frozen
    // refusal returns before dispatchV2 reaches this hook; a decode failure
    // throws before dispatchV2 is reached at all. Neither increments the
    // counter.
    let coachingIngress: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?) = {
        toolName, arguments in
        await modeSessionState.recordCall(toolName: toolName, mode: nil)
        return (arguments, nil)
    }

    // MARK: Coaching egress hook (transform — not a gate)

    // The transform phase runs before decode so a hook can remove a key the
    // strict decoder rejects. Counting runs after the frozen guard because a
    // refused call is not a call.
    //
    // Order preserved from the inline implementation this hook replaces:
    //   1. Hint injection: AriaV2Coach.coachingHint → AriaV2Envelope.applyHint.
    //      Suppressed on error results by AriaV2Coach (§12.5 RULING 3).
    //   2. Periodic block: shouldCoach → snapshot → PeriodicCoach.renderBlock
    //      → AriaV2Envelope.applyCoachingBlock.
    //      Applied to all results including error results.
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
