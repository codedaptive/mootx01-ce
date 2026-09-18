import Foundation
import AriaMCPWire

/// Typed `moot_help` input.  Intent and tool are mutually exclusive.
public struct AriaV2HelpRequest: Sendable, Equatable {
    public let intent: String?
    public let tool: String?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments,
            allowedKeys: ["intent", "tool"]
        )
        if decoder.has("intent") && decoder.has("tool") {
            _ = try decoder.requireExactlyOne(of: ["intent", "tool"])
        }
        self.intent = try decoder.optionalString("intent")
        self.tool = try decoder.optionalString("tool")
    }
}

/// A non-callable help record.  It remains outside `tools/list` even when it
/// is returned by the help directory.
public struct AriaV2HelpDirectoryRecord: Sendable, Equatable {
    public let recipeID: String
    public let description: String
    public let callableTools: [String]
    public let availability: AriaV2OperationAvailability
    public let isCallable: Bool

    public init(
        recipeID: String,
        description: String,
        callableTools: [String],
        availability: AriaV2OperationAvailability = .init()
    ) {
        precondition(!recipeID.isEmpty, "A v2 help record identifier must not be empty.")
        self.recipeID = recipeID
        self.description = description
        self.callableTools = callableTools
        self.availability = availability
        self.isCallable = false
    }
}

public enum AriaV2HelpResult: Sendable, Equatable {
    case directory(
        operations: [AriaV2OperationDescriptor],
        directoryRecords: [AriaV2HelpDirectoryRecord]
    )
    case operation(AriaV2OperationDescriptor)
    case intent(intent: String, operations: [AriaV2OperationDescriptor])
}

/// Resolves help strictly against the effective registry for one selected
/// build/lane/capability context.
public struct AriaV2HelpService: Sendable {
    public let registry: AriaV2EffectiveRegistry
    public let directoryRecords: [AriaV2HelpDirectoryRecord]
    public let buildID: String

    public init(
        registry: AriaV2EffectiveRegistry,
        directoryRecords: [AriaV2HelpDirectoryRecord] = [],
        buildID: String? = nil
    ) {
        self.registry = registry
        self.buildID = buildID ?? registry.inputs.buildID
        self.directoryRecords = directoryRecords
            .filter { $0.availability.isSatisfied(by: registry.inputs) }
            .sorted { $0.recipeID < $1.recipeID }
    }

    public func resolve(_ request: AriaV2HelpRequest) -> AriaV2HelpResult? {
        if let tool = request.tool {
            return registry.operation(named: tool).map(AriaV2HelpResult.operation)
        }
        if let intent = request.intent {
            let normalized = intent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches = registry.operations.filter { descriptor in
                descriptor.help.intents.contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                }
            }
            return .intent(intent: intent, operations: matches)
        }
        return .directory(
            operations: registry.operations,
            directoryRecords: directoryRecords
        )
    }

    public func render(_ request: AriaV2HelpRequest) -> JSONValue {
        guard let result = resolve(request) else {
            return AriaV2Envelope.refusal(
                tool: "moot_help",
                error: .init(
                    code: "unknown_operation",
                    message: "No callable ARIA v2 operation matched that help request.",
                    retryable: false,
                    recovery: .object(["tool": .string("moot_help"), "arguments": .object([:])])
                )
            )
        }

        let data: JSONValue
        switch result {
        case .operation(let operation):
            data = .object(["operation": Self.operationValue(operation)])
        case .intent(let intent, let operations):
            data = .object([
                "intent": .string(intent),
                "operations": .array(operations.map(Self.operationValue)),
            ])
        case .directory(let operations, let records):
            data = .object([
                "operations": .array(operations.map(Self.operationValue)),
                "directory_records": .array(records.map { record in
                    .object([
                        "recipe_id": .string(record.recipeID),
                        "description": .string(record.description),
                        "callable": .bool(false),
                        "callable_tools": .array(record.callableTools.map(JSONValue.string)),
                    ])
                }),
                // Global modifiers are documented once here at the directory level,
                // absent from every per-tool input schema and per-operation help.
                // Byte-identical to the Rust GLOBAL_MODIFIERS_HELP_TEXT constant;
                // pinned by Tests/Conformance/global_modifiers_help_fixture.json.
                "global_modifiers": .string(Self.globalModifiersHelpText),
            ])
        }
        return AriaV2Envelope.success(
            tool: "moot_help",
            effect: .read,
            data: data,
            meta: [
                "build_id": .string(buildID),
                "capability_digest": .string(try! AriaV2CapabilityDigest.digest(registry: registry)),
                "completeness": .string("incomplete"),
            ],
            compactText: "ARIA v2 help returned the exact currently callable operation set."
        )
    }

    private static func operationValue(_ operation: AriaV2OperationDescriptor) -> JSONValue {
        .object([
            "id": .string(operation.identity.rawValue),
            "name": .string(operation.publicName),
            "description": .string(operation.help.description),
            "effect": .string(operation.effect.rawValue),
            "input_schema": operation.inputSchema,
            "output_schema": operation.projection.outputSchema,
            "intents": .array(operation.help.intents.map(JSONValue.string)),
        ])
    }

    /// The global-modifiers help entry returned in the moot_help directory payload.
    ///
    /// Documented once here at the directory level. Absent from every per-tool input
    /// schema and per-operation help text (the documented-once contract). Byte-identical
    /// to the Rust `GLOBAL_MODIFIERS_HELP_TEXT` constant; pinned by
    /// `Tests/Conformance/global_modifiers_help_fixture.json` in both ports.
    static let globalModifiersHelpText: String =
        "mode \u{2014} global modifier applied at the ARIA door before every operation decodes its arguments.\n" +
        "Grammar: mode:\"Name\" sets the mode; mode:\"Name=Variant\" sets mode and variant; " +
        "a bare name clears any prior variant for that mode; the last declaration on a call wins.\n" +
        "Fail-open: an unknown mode name or variant is silently ignored and does not clobber existing sticky state.\n" +
        "Excluded (own mode in their input schema): moot_reclassify_fdc, moot_palace_import, moot_vault_import, moot_lens_partial_cue.\n" +
        "report_withheld — per-call global modifier; only true enables it (default off). For precise, shaped, vague, connected, distilled, federated and transcript recall, and partial-cue, keystones and trust-synthesis lenses, adds integer meta.withheldBySensitivity: primary candidates excluded only by LocusKit's default adjective-sensitivity ceiling while all other frame predicates admit. An explicit sensitivity filter yields zero. Keystones counts only ranked topK endpoint drawers rejected at hydration by that ceiling, not all graph endpoints. Later provenance projection and tunnel counts are separate. Rows and ordering are unchanged; the key is absent when off.\n" +
        "chest_diversity — per-call global modifier; on or off (default: the estate preference chest_recall_diversity). On moot_memory_search, on treats two hits in one chest as one topic in the diversity rerank; off uses the shingle term alone. Any other value is ignored."
}
