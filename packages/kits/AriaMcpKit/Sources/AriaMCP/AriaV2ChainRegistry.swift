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

    /// Transform position 1: used by the mode concern to strip the `mode` global
    /// modifier and inject the sticky recall `answer` arg before decode.
    ///
    /// The transform phase runs before `AriaSurfaceDecoder` so a hook can remove
    /// or add a key before the strict decoder sees the arguments. The mode concern
    /// occupies this position in production via `ariaV2PreDecodeRegistrations`.
    static let transformReserved: Int = 1

    // MARK: Ingress (record phase)

    /// Mode concern reads the pending declaration at ingress position 5, before
    /// coaching at position 10 clears it.
    ///
    /// Returns the `unknownHint` text as per-concern ingress state so the mode
    /// egress hook at position 20 can append the hint without re-reading actor state.
    static let ingressMode: Int = 5

    /// Session-accounting concern (`recordCall`) runs at ingress position 10.
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

    /// Mode hint egress runs at position 20, after the coaching hint at position 10.
    ///
    /// Appends an `unknownHint` line when the transform phase parsed a mode
    /// declaration whose name or variant is not recognised. Recognised modes
    /// (e.g. `Recall=Auto`) produce no hint here.
    static let egressMode: Int = 20
}

// MARK: - Pre-decode registration factory

/// Return the call-local global mode declaration, excluding operations whose
/// input schema owns the `mode` argument for its own business semantics.
func ariaV2GlobalModeDeclaration(
    toolName: String,
    arguments: [String: JSONValue],
    environment: [String: String]
) -> ModeDeclaration? {
    guard case .string(let rawMode) = arguments["mode"],
          !ariaV2OperationOwnsMode(toolName: toolName, environment: environment)
    else { return nil }
    return ModeDeclaration.parse(rawMode)
}

private func ariaV2OperationOwnsMode(
    toolName: String,
    environment: [String: String]
) -> Bool {
    let registry = AriaV2SelectedCatalog.registry(environment: environment)
    guard let operation = registry.operation(named: toolName),
          case .object(let schema) = operation.inputSchema,
          let propsValue = schema["properties"],
          case .object(let props) = propsValue
    else { return false }
    return props["mode"] != nil
}

/// Build the pre-decode (transform-phase) chain registration for one v2 call.
///
/// Called per call from `ToolDispatcher.dispatch` before `AriaSurfaceDecoder.decode`.
/// These registrations carry ONLY transform hooks; no ingress or egress hooks are
/// present.
///
/// The mode concern's transform hook performs two jobs, in order:
///   1. **Recall answer injection:** when `answer` is absent and the tool is
///      `moot_memory_search` and the session has a sticky Recall variant, injects
///      the variant's answer-mode raw value as the `answer` arg before decode.
///      Per-call explicit `answer` always wins — injection only fires when the key
///      is absent.
///   2. **Mode arg stripping:** strips the `mode` global modifier from arguments so
///      the strict decoder never sees it, unless the operation owns `mode` in its
///      `inputSchema` (collision). The dispatcher parses the declaration from the
///      original arguments and carries it directly into this call's post-decode
///      registrations.
///
/// - Parameters:
///   - environment: The process-environment dictionary used to select the v2 catalog.
///   - modeSessionState: The per-session state actor.
/// The report_withheld transform follows mode and strips its call-local opt-in.
/// - Returns: Transform-only registrations for mode and report_withheld.
func ariaV2PreDecodeRegistrations(
    environment: [String: String],
    modeSessionState: ModeSessionState
) -> [AriaV2ChainRegistration] {

    let transformHook: @Sendable (String, JSONValue) async throws -> JSONValue = { toolName, arguments in
        var args = arguments.objectValue ?? [:]

        // --- Recall answer injection (before mode stripping) ---
        // Per-call explicit `answer` always wins. Only inject when the key is absent,
        // the tool is moot_memory_search, and the session has a sticky Recall variant.
        // The injected value causes AriaSurfaceDecoder to decode answer=<variant> rather
        // than defaulting to PackagerAnswerMode.never, enabling the auto/always gate path.
        if toolName == "moot_memory_search",
           args["answer"] == nil,
           let answerMode = await modeSessionState.stickyRecallAnswerMode {
            args["answer"] = .string(answerMode)
        }

        // --- Mode arg stripping ---
        // Ownership is read at runtime from AriaV2SelectedCatalog.registry(environment:) —
        // the v2 registry, not the v1 projected-tool list. Currently three operations declare
        // `mode` in their v2 inputSchema: moot_reclassify_fdc, moot_palace_import,
        // moot_vault_import. An operation added later that declares `mode` is excluded here
        // automatically, without a code change. When an operation owns `mode`, the key is
        // left untouched — the decoder will see and handle it normally.
        if args["mode"] != nil {
            if !ariaV2OperationOwnsMode(toolName: toolName, environment: environment) {
                // Strip the global modifier so the strict decoder never sees it.
                args["mode"] = nil
            }
        }
        return .object(args)
    }

    return [
        AriaV2ChainRegistration(
            concernName: "mode",
            transform: (position: AriaV2ChainPositions.transformReserved, hook: transformHook)
        ),
        AriaV2ChainRegistration(concernName: "report_withheld", transform: (position: 2, hook: { _, arguments in
            guard var args = arguments.objectValue else { return arguments }
            await AriaV2Withheld.call?.configure(args.removeValue(forKey: "report_withheld"))
            return .object(args)
        }))
    ]
}

// MARK: - Production registration factory

/// Build the post-decode production chain registrations for one v2 call.
///
/// Called per call because coaching's egress hook captures the decoded request
/// and the session state, both of which vary per call.
///
/// Three registrations are returned:
///   - `"mode"`: ingress at position 5, egress at position 20.
///   - `"coaching"`: ingress at position 10, egress at position 10.
///   - `"report_withheld"`: conditional metadata egress at position 30.
///
/// **Ingress order** (5 before 10): the mode ingress reads `pendingDeclaration`
/// and returns its `unknownHint` as per-concern state, before coaching at position 10
/// reads the same stash and calls `recordCall`.
///
/// **Egress order** (10 before 20): coaching hint fires first; mode hint appends
/// after it, so coaching and mode hints appear in that order in the wire text.
///
/// Construction can only fail on a duplicate concern name or a duplicate
/// position, both programmer errors in this hard-coded list. Use `try!` at
/// the call site (precedent: ToolDispatch.swift `try! AriaV2CapabilityDigest.digest`).
///
/// - Parameters:
///   - request: The decoded `AriaSurfaceRequest` for this call.
///   - modeSessionState: The per-session state actor.
/// - Returns: Two registrations, concern names `"mode"` and `"coaching"`.
func ariaV2ProductionRegistrations(
    request: AriaSurfaceRequest,
    modeSessionState: ModeSessionState,
    modeDeclaration: ModeDeclaration? = nil
) -> [AriaV2ChainRegistration] {

    // MARK: Mode ingress hook (position 5)
    //
    // Reads the call-local declaration supplied by the dispatcher and returns
    // its `unknownHint` text as per-concern ingress state. The mode
    // egress hook at position 20 receives this state and calls `applyHint`.
    //
    let modeIngress: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?) = {
        _, arguments in
        // Per-concern state: bare unknownHint text as a string JSONValue, or nil.
        // AriaV2Envelope.applyHint adds the "hint: " prefix — pass the bare text here.
        let state: JSONValue? = modeDeclaration?.unknownHint.map { .string($0) } ?? nil
        return (arguments, state)
    }

    // MARK: Mode egress hook (position 20)
    //
    // Applies the unknown-mode hint to the result when per-concern state is
    // present. Recognised modes (e.g. Recall=Auto) have no unknownHint so this
    // hook is a no-op for them. Never fires on error results (applyHint guards).
    let modeEgress = AriaV2EgressHook.transform({ _, result, state in
        guard let state, case .string(let hint) = state else { return result }
        return AriaV2Envelope.applyHint(hint, to: result)
    })

    // MARK: Coaching ingress (record) hook (position 10)
    //
    // Records the call-local declaration so sticky state and call counters are
    // updated for this call only.
    //
    // The ingress (record) phase runs after decode and after the frozen-mutation
    // guard. Counting runs here because a refused or decode-failed call is not a
    // call. The transform phase runs before decode and must not advance the counter.
    let coachingIngress: @Sendable (String, JSONValue) async throws -> (JSONValue, JSONValue?) = {
        toolName, arguments in
        await modeSessionState.recordCall(toolName: toolName, mode: modeDeclaration)
        return (arguments, nil)
    }

    // MARK: Coaching egress hook (position 10, transform — not a gate)
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
            concernName: "mode",
            ingress: (position: AriaV2ChainPositions.ingressMode, hook: modeIngress),
            egress: (position: AriaV2ChainPositions.egressMode, hook: modeEgress)
        ),
        AriaV2ChainRegistration(
            concernName: "coaching",
            ingress: (position: AriaV2ChainPositions.ingressCoaching, hook: coachingIngress),
            egress: (position: AriaV2ChainPositions.egressCoaching, hook: coachingEgress)
        ),
        AriaV2ChainRegistration(concernName: "report_withheld", egress: (position: 30, hook: .transform({ _, result, _ in
            await AriaV2Withheld.egress(result)
        }))),
    ]
}
