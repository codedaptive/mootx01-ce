import AriaMCPWire

/// The first bounded v2 typed operation.  It intentionally models only the
/// read-only monitoring inspection; the monitoring write operation belongs to
/// the later v2 surface work.
enum AriaV2MonitoringInspection {
    static let toolName = "moot_monitoring_status"

    struct Request: Sendable {
        init(arguments: [String: JSONValue]) throws {
            guard arguments.isEmpty else {
                let argument = arguments.keys.sorted().first ?? "arguments"
                let message = "moot_monitoring_status is inspection-only in ARIA v2 and accepts no arguments"
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: message,
                    data: .object([
                        "code": .string("invalid_argument"),
                        "path": .string(argument),
                        "message": .string(message),
                        "correction": .string("Call moot_monitoring_status with an empty arguments object."),
                    ])
                )
            }
        }
    }

    enum State: String, Sendable {
        case enabled
        case disabled
        case unavailable

        init(enabled: Bool?) {
            switch enabled {
            case true: self = .enabled
            case false: self = .disabled
            case nil: self = .unavailable
            }
        }
    }

    struct Result: Sendable {
        let state: State
    }

    static func execute(
        _ request: Request,
        monitoringControl: (any MonitoringControl)?
    ) async -> Result {
        _ = request
        return Result(state: State(enabled: await monitoringControl?.read()))
    }

    static func render(
        _ result: Result,
        buildID: String = "aria-v2",
        capabilityDigest: String = AriaV2SelectedCatalog.capabilityDigest
    ) -> JSONValue {
        let state = result.state.rawValue
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("monitoring: \(state)\nsurface: v2 (incomplete)"),
                ]),
            ]),
            "structuredContent": .object([
                "surface_version": .string("v2"),
                "tool": .string(toolName),
                "data": .object(["monitoring": .string(state)]),
                "meta": .object([
                    "build_id": .string(buildID),
                    "capability_digest": .string(capabilityDigest),
                    "completeness": .string("incomplete"),
                    "effect": .string("read"),
                ]),
            ]),
            "isError": .bool(false),
        ])
    }

    static func projectedTool() -> ProjectedTool {
        ProjectedTool(
            name: toolName,
            description: "Inspect the current daemon telemetry monitoring state. This operation is read-only and accepts no arguments.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            provenance: .interface,
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "surface_version": .object(["type": .string("string")]),
                    "tool": .object(["type": .string("string")]),
                    "data": .object(["type": .string("object")]),
                    "meta": .object(["type": .string("object")]),
                ]),
                "required": .array([
                    .string("surface_version"), .string("tool"),
                    .string("data"), .string("meta"),
                ]),
            ])
        )
    }
}
