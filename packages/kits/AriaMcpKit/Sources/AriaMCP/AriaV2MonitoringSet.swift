import AriaMCPWire

/// Typed write core for `moot_monitoring_set`.
///
/// This deliberately has no selected-surface registration or dispatcher
/// dependency.  The integration owner supplies the selected catalog and calls
/// this typed core only after v2 routing and write-policy checks succeed.
public enum AriaV2MonitoringSet {
    public static let toolName = "moot_monitoring_set"

    /// The v2 write contract is exactly `{enabled: bool}`.
    public struct Request: Sendable, Equatable {
        public let enabled: Bool

        public init(arguments: JSONValue) throws {
            let decoder = try AriaV2ArgumentDecoder(arguments, allowedKeys: ["enabled"])
            enabled = try decoder.requireBoolean("enabled")
        }
    }

    /// A completed write is returned only after a read confirms the effective
    /// stored state.  A refusal retains the distinction between unavailable
    /// control and a write whose post-write state could not be verified.
    public enum Result: Sendable, Equatable {
        case confirmed(enabled: Bool)
        case refusal(AriaV2OperationalRefusal)
    }

    /// Set the requested value directly, then re-read the control before
    /// reporting success.  `MonitoringControl.set` is best-effort and cannot
    /// tell us whether persistence survived, so nil readback is never rendered
    /// as a successful enabled or disabled state.
    public static func execute(
        _ request: Request,
        monitoringControl: (any MonitoringControl)?
    ) async -> Result {
        guard let monitoringControl else {
            return .refusal(AriaV2OperationalRefusal(
                code: "monitoring_unavailable",
                message: "Monitoring control is unavailable in this daemon context.",
                retryable: false
            ))
        }

        await monitoringControl.set(request.enabled)
        guard let confirmed = await monitoringControl.read(), confirmed == request.enabled else {
            return .refusal(AriaV2OperationalRefusal(
                code: "monitoring_unverified",
                message: "The monitoring write may have landed, but its effective state could not be confirmed.",
                retryable: false,
                recovery: .object([
                    "tool": .string(AriaV2MonitoringInspection.toolName),
                    "arguments": .object([:]),
                ])
            ))
        }
        return .confirmed(enabled: confirmed)
    }

    /// Render a confirmed write as the typed v2 success envelope, or a typed
    /// operational refusal.  Build metadata is injected by the later selected
    /// surface rather than read from process state here.
    public static func render(
        _ result: Result,
        buildID: String,
        capabilityDigest: String
    ) -> JSONValue {
        switch result {
        case .confirmed(let enabled):
            let state = enabled ? "enabled" : "disabled"
            return AriaV2Envelope.success(
                tool: toolName,
                effect: .write,
                data: .object(["monitoring": .string(state)]),
                meta: [
                    "build_id": .string(buildID),
                    "capability_digest": .string(capabilityDigest),
                    "completeness": .string("incomplete"),
                ],
                compactText: "Monitoring is \(state)."
            )
        case .refusal(let refusal):
            return AriaV2Envelope.refusal(tool: toolName, error: refusal)
        }
    }
}
