import AriaMCPWire
import Foundation

/// The fixed operation contract for authenticated native applications.
///
/// This is deliberately separate from `AriaV2SelectedCatalog`: public MCP
/// selection may change with build capabilities, while a native application's
/// capture/read contract must remain independently versioned.  The authenticated
/// composition root supplies the selected estate and caller context; neither is
/// accepted from this catalog's tool arguments.
public enum FirstPartyProviderCatalog {
    public static let providerName = "FirstPartyProvider"
    public static let contractVersion = "1.1.0"
    public static let legacyContractVersion = "1.0.0"
    public static let legacyCapabilityDigest = "88d682d7dd74754040b9a6ae5c81c9ddabcb830ee1fc0d0891e573edbebbfde7"
    public static let supportedARIAVersion = "v2"
    public static let capabilities = [
        "memory.capture", "memory.read", "memory.mutate", "memory.connect",
        "fact.capture", "fact.read", "fact.retire", "journal.read",
        "recall.precise", "cognition.review", "estate.inspect",
    ]

    public static let descriptors: [AriaV2OperationDescriptor] = [
        descriptor(
            identity: "first_party_memory_capture",
            name: "moot_file_memory",
            effect: .write,
            description: "Capture a durable memory in the authenticated caller's selected estate.",
            properties: [
                "content": stringSchema(),
                "subject": stringSchema(),
                "location": stringSchema(),
                "wing": stringSchema(),
                "sensitivity": enumSchema(["normal", "elevated", "restricted", "secret"]),
                "exportability": enumSchema(["private", "public"]),
                "kind": enumSchema(["prose", "code", "transcript", "list", "structured_json", "image_caption"]),
                "event_time": dateTimeSchema(),
                "impatient": booleanSchema(),
            ],
            required: ["content", "subject", "location"]
        ),
        descriptor(
            identity: "first_party_memory_read",
            name: "moot_memory_get",
            effect: .read,
            description: "Read one authorized memory from the authenticated caller's selected estate.",
            properties: [
                "memory_id": uuidSchema(),
            ],
            required: ["memory_id"]
        ),
        descriptor(identity: "first_party_memory_list", name: "moot_memory_list", effect: .read,
                   description: "List authorized memory structure in the authenticated caller's selected estate.",
                   properties: ["wing": nonEmptyStringSchema(), "room": stringSchema(), "filter": enumSchema(["missing_subject"]), "limit": positiveIntegerSchema(), "cursor": nonEmptyStringSchema()], required: ["wing"]),
        descriptor(identity: "first_party_memory_search", name: "moot_memory_search", effect: .read,
                   description: "Search authorized memories in the authenticated caller's selected estate.",
                   properties: ["query": stringSchema(), "near": uuidSchema(), "limit": positiveIntegerSchema(), "filter": enumSchema(["exportable"])],
                   required: [], exactlyOneOf: [("query", "near")]),
        descriptor(identity: "first_party_memory_update", name: "moot_update_memory", effect: .write,
                   description: "Change one explicit mutable field of an authorized memory.",
                   properties: ["id": uuidSchema(), "memory_id": uuidSchema(), "mutation": enumSchema(["confirm", "reject", "contest", "resolve", "supersede", "revive", "accept", "set_subject", "correct_sensitivity", "correct_exportability"]), "subject": boundedStringSchema(minimum: 1, maximum: 120), "sensitivity": sensitivitySchema(), "exportability": exportabilitySchema(), "note": stringSchema()], required: ["mutation"], exactlyOneOf: [("id", "memory_id")]),
        descriptor(identity: "first_party_memory_withdraw", name: "moot_withdraw_memory", effect: .write,
                   description: "Withdraw one memory from ordinary recall while retaining its audit history.",
                   properties: ["id": uuidSchema(), "memory_id": uuidSchema(), "reason": stringSchema()], required: [], exactlyOneOf: [("id", "memory_id")]),
        descriptor(identity: "first_party_memory_erase", name: "moot_erase_memory", effect: .write,
                   description: "Permanently erase one memory after explicit confirmation.",
                   properties: ["id": uuidSchema(), "memory_id": uuidSchema(), "confirmed": trueSchema(), "confirmation": trueSchema(), "reason": stringSchema()], required: [], exactlyOneOf: [("id", "memory_id"), ("confirmed", "confirmation")]),
        descriptor(identity: "first_party_memory_confirm", name: "moot_confirm_memory", effect: .write,
                   description: "Mark one authorized memory as user-confirmed.",
                   properties: ["id": uuidSchema(), "memory_id": uuidSchema()], required: [], exactlyOneOf: [("id", "memory_id")]),
        descriptor(identity: "first_party_memory_move", name: "moot_move_memory", effect: .write,
                   description: "Move one authorized memory to a location, retaining its current wing when wing is omitted.",
                   properties: ["id": uuidSchema(), "memory_id": uuidSchema(), "location": nonEmptyStringSchema(), "room": nonEmptyStringSchema(), "wing": nonEmptyStringSchema()], required: [], exactlyOneOf: [("id", "memory_id"), ("location", "room")]),
        descriptor(identity: "first_party_memory_link", name: "moot_link_memories", effect: .write,
                   description: "Create a directed typed connection between two authorized memories.",
                   properties: ["from_id": uuidSchema(), "to_id": uuidSchema(), "relationship": relationshipSchema(), "confidence": stringSchema(), "evidence": stringSchema()], required: ["from_id", "to_id", "relationship"]),
        descriptor(identity: "first_party_tunnel_review", name: "moot_review_tunnel", effect: .write,
                   description: "Review a proposed connection and record its settled lifecycle.",
                   properties: ["tunnel_id": uuidSchema(), "verdict": enumSchema(["accept", "endorse", "reject"]), "decision": enumSchema(["accept", "endorse", "reject"]), "note": stringSchema()], required: ["tunnel_id"], exactlyOneOf: [("verdict", "decision")]),
        descriptor(identity: "first_party_fact_capture", name: "moot_file_fact", effect: .write,
                   description: "Store a typed fact, optionally grounded in a source memory.",
                   properties: ["subject": stringSchema(), "predicate": stringSchema(), "object": stringSchema(), "source_memory_id": uuidSchema(), "event_time": dateTimeSchema()], required: ["subject", "predicate", "object"]),
        descriptor(identity: "first_party_fact_search", name: "moot_fact_search", effect: .read,
                   description: "Search authorized facts by text or typed fact fields.",
                   properties: ["query": stringSchema(), "subject": stringSchema(), "predicate": stringSchema(), "object": stringSchema(), "source_id_exact": stringSchema(), "subject_exact": stringSchema(), "limit": positiveIntegerSchema()], required: []),
        descriptor(identity: "first_party_fact_retire", name: "moot_retire_fact", effect: .write,
                   description: "Retire one fact with an explicit reason.",
                   properties: ["id": uuidSchema(), "fact_id": uuidSchema(), "reason": stringSchema()], required: [], exactlyOneOf: [("id", "fact_id")]),
        descriptor(identity: "first_party_journal_read", name: "moot_read_journal", effect: .read,
                   description: "Read authorized journal entries in recorded order.",
                   properties: ["limit": positiveIntegerSchema(), "before": stringSchema(), "after": stringSchema()], required: []),
        descriptor(identity: "first_party_recall_precise", name: "moot_recall_precise", effect: .read,
                   description: "Recall authorized memories with the typed precision composition.",
                   properties: ["query": nonEmptyStringSchema(), "limit": positiveIntegerSchema(), "filter": enumSchema(["exportable"])], required: ["query"]),
        descriptor(identity: "first_party_lenses", name: "moot_list_lenses", effect: .read,
                   description: "List callable cognition lenses available to the authenticated provider.",
                   properties: ["verbose": booleanSchema()], required: []),
        descriptor(identity: "first_party_lens_keystones", name: "moot_lens_keystones", effect: .read,
                   description: "Identify authorized memory hubs by graph centrality.",
                   properties: ["wing": stringSchema(), "topK": positiveIntegerSchema(), "keystoneOnly": booleanSchema()], required: ["wing"]),
        descriptor(identity: "first_party_lens_theme_weather", name: "moot_lens_theme_weather", effect: .read,
                   description: "Measure temporal momentum for authorized themes.", properties: [:], required: []),
        descriptor(identity: "first_party_lens_cohesion", name: "moot_lens_cohesion", effect: .read,
                   description: "Find authorized low-cohesion memories or dataset anomalies.", properties: ["dataset_id": uuidSchema()], required: []),
        descriptor(identity: "first_party_lens_contradiction", name: "moot_lens_contradiction", effect: .read,
                   description: "Surface authorized recorded contradictions and proposed findings.", properties: [:], required: []),
        descriptor(identity: "first_party_lens_drift", name: "moot_lens_drift", effect: .read,
                   description: "Measure authorized distribution drift across a temporal split.", properties: ["splitAt": stringSchema()], required: ["splitAt"]),
        descriptor(identity: "first_party_estate_status", name: "moot_estate_status", effect: .read,
                   description: "Inspect selected-estate status and effective surface metadata.", properties: [:], required: []),
        descriptor(identity: "first_party_drain_status", name: "moot_drain_status", effect: .read,
                   description: "Inspect selected-estate background drain progress.", properties: [:], required: []),
        descriptor(identity: "first_party_rebuild_status", name: "moot_rebuild_status", effect: .read,
                   description: "Inspect selected-estate derived-state rebuild progress.", properties: [:], required: []),
        descriptor(identity: "first_party_timing_report", name: "moot_timing_report", effect: .read,
                   description: "Inspect selected-estate operation timing diagnostics.", properties: [:], required: []),
    ]

    /// A registry has no public-build or environment inputs.  The fixed
    /// first-party lane is the only selection context for this contract.
    public static let registry: AriaV2EffectiveRegistry = try! .init(
        descriptors: descriptors,
        inputs: .init(
            buildID: "first-party-provider-contract-1.1",
            lane: .firstParty,
            capabilities: []
        )
    )

    public static let capabilityDigest: String = try! AriaV2CapabilityDigest.digest(registry: registry)

    public static var projectedTools: [ProjectedTool] {
        registry.projectedTools
    }

    public static var discovery: FirstPartyProviderDiscovery {
        .init(
            providerName: providerName,
            contractVersion: contractVersion,
            ariaSupportedVersion: supportedARIAVersion,
            capabilities: capabilities,
            capabilityDigest: capabilityDigest
        )
    }

    /// Accept the currently advertised contract or the exact 1.0 tuple.  The
    /// latter is retained for already-shipped clients and is paired with the
    /// 1.0 argument grammar below; version claims never unlock newer fields.
    public static func admittedContractVersion(_ compatibility: [String: JSONValue]) -> String? {
        guard Set(compatibility.keys) == ["contract_version", "aria_supported_version", "capability_digest"],
              compatibility["aria_supported_version"]?.stringValue == supportedARIAVersion,
              let version = compatibility["contract_version"]?.stringValue,
              let digest = compatibility["capability_digest"]?.stringValue else { return nil }
        if version == contractVersion, digest == capabilityDigest { return version }
        if version == legacyContractVersion, digest == legacyCapabilityDigest { return version }
        return nil
    }

    /// The fixed catalog is the stable provider's executable admission
    /// authority.  Lower v2 adapters have broader, evolving grammars; stable
    /// calls never reach them with an undeclared key or a value that violates
    /// the advertised fixed schema.
    public static func validateArguments(
        name: String,
        arguments: [String: JSONValue],
        contractVersion admittedVersion: String = contractVersion
    ) throws {
        guard let descriptor = registry.operation(named: name),
              let schema = descriptor.inputSchema.objectValue,
              let properties = schema["properties"]?.objectValue else {
            throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(name)")
        }
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)) else {
            let unknown = arguments.keys.filter { properties[$0] == nil }.sorted().joined(separator: ", ")
            // Derived from AriaV2ArgumentDecoder.swift:53-58: path "arguments" with the declared
            // keys as allowed, so callers can see the valid surface in one error response.
            throw AriaV2InvalidArgument(
                path: "arguments",
                message: "Undeclared argument(s) for \(name): \(unknown).",
                allowed: properties.keys.sorted(),
                correction: "Remove the argument or use one of the declared keys."
            ).jsonRPCError
        }
        if admittedVersion == legacyContractVersion {
            let additions: Set<String>
            switch name {
            case "moot_memory_search", "moot_recall_precise": additions = ["filter"]
            case "moot_fact_search": additions = ["source_id_exact", "subject_exact"]
            case "moot_update_memory", "moot_withdraw_memory", "moot_confirm_memory", "moot_retire_fact": additions = ["id"]
            case "moot_erase_memory": additions = ["id", "confirmed"]
            case "moot_move_memory": additions = ["id", "location"]
            case "moot_review_tunnel": additions = ["verdict"]
            default: additions = []
            }
            let newer = Set(arguments.keys).intersection(additions)
            guard newer.isEmpty else {
                // Same shape as the undeclared-args refusal above: path "arguments",
                // allowed is the subset available at the legacy version.
                throw AriaV2InvalidArgument(
                    path: "arguments",
                    message: "Argument(s) \(newer.sorted().joined(separator: ", ")) require FirstPartyProvider 1.1.0.",
                    allowed: properties.keys.filter { !additions.contains($0) }.sorted(),
                    correction: "Upgrade the caller to FirstPartyProvider 1.1.0 or remove the unsupported argument."
                ).jsonRPCError
            }
            if name == "moot_move_memory", arguments["wing"] == nil {
                // Derived from AriaV2RecallLens.swift:43: path is the key, message is canonical.
                throw AriaV2InvalidArgument(
                    path: "wing",
                    message: "Missing required argument 'wing'."
                ).jsonRPCError
            }
        }
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            // Derived from AriaV2RecallLens.swift:43: path is the key, message is canonical.
            guard arguments[key] != nil else {
                throw AriaV2InvalidArgument(
                    path: key,
                    message: "Missing required argument '\(key)'."
                ).jsonRPCError
            }
        }
        let alternativeGroups = (schema["oneOf"].map { [$0] } ?? [])
            + (schema["allOf"]?.arrayValue ?? []).compactMap { $0.objectValue?["oneOf"] }
        for group in alternativeGroups {
            guard let alternatives = group.arrayValue else { continue }
            let matched = alternatives.filter { alternative in
                guard let object = alternative.objectValue else { return false }
                let required = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let forbidden = object["not"]?.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return required.allSatisfy { arguments[$0] != nil } && forbidden.allSatisfy { arguments[$0] == nil }
            }
            guard matched.count == 1 else {
                // Derived from AriaV2ArgumentDecoder.swift:139-143: path is the alternatives
                // joined with "|", allowed is the same set, correction states the constraint.
                let keys = alternatives.flatMap { alt -> [String] in
                    guard let obj = alt.objectValue else { return [] }
                    return obj["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                }.sorted()
                throw AriaV2InvalidArgument(
                    code: "conflicting_arguments",
                    path: keys.joined(separator: "|"),
                    message: "Provide exactly one of \(keys.joined(separator: ", ")).",
                    allowed: keys,
                    correction: "Remove the conflicting argument or provide one required argument."
                ).jsonRPCError
            }
        }
        for (key, value) in arguments {
            guard let property = properties[key]?.objectValue else { continue }
            try validate(value: value, property: property, key: key)
        }
    }

    private static func validate(value: JSONValue, property: [String: JSONValue], key: String) throws {
        // Derived from AriaV2ArgumentDecoder.swift:178-183 (invalidScalar): path: key,
        // message and correction name the expected type.
        switch property["type"]?.stringValue {
        case "string":
            guard value.stringValue != nil else {
                throw AriaV2InvalidArgument(
                    path: key,
                    message: "Argument '\(key)' must be a string.",
                    correction: "Provide \(key) as a string."
                ).jsonRPCError
            }
        case "integer":
            guard value.integerValue != nil else {
                throw AriaV2InvalidArgument(
                    path: key,
                    message: "Argument '\(key)' must be an integer.",
                    correction: "Provide \(key) as an integer."
                ).jsonRPCError
            }
        case "boolean":
            guard value.boolValue != nil else {
                throw AriaV2InvalidArgument(
                    path: key,
                    message: "Argument '\(key)' must be a boolean.",
                    correction: "Provide \(key) as a boolean."
                ).jsonRPCError
            }
        default: break
        }
        if let enumValues = property["enum"]?.arrayValue, !enumValues.contains(value) {
            // Every enum in this catalog is built by enumSchema(_:), which maps [String] to
            // JSONValue.string, so every member is a string. Non-string members are dropped
            // from the hint via compactMap; the refusal remains correct because the
            // containment check above uses the full JSONValue array. jsonRPCError sorts
            // allowed before encoding (AriaV2ArgumentDecoder.swift:33), so no pre-sort needed.
            let allowedStrings = enumValues.compactMap { $0.stringValue }
            throw AriaV2InvalidArgument(
                path: key,
                message: "Argument '\(key)' is not one of the declared values.",
                allowed: allowedStrings.isEmpty ? nil : allowedStrings
            ).jsonRPCError
        }
        // For const, minimum, minLength, maxLength, and uuid format there is no enumerated
        // allowed list — the schema constraint IS the constraint, so correction states it.
        if let constant = property["const"], value != constant {
            throw AriaV2InvalidArgument(
                path: key,
                message: "Argument '\(key)' must equal its declared constant.",
                correction: "Provide '\(key)' equal to its declared constant value."
            ).jsonRPCError
        }
        if let minimum = property["minimum"]?.integerValue,
           let integer = value.integerValue, integer < minimum {
            throw AriaV2InvalidArgument(
                path: key,
                message: "Argument '\(key)' is below its declared minimum.",
                correction: "Argument '\(key)' must be at least \(minimum)."
            ).jsonRPCError
        }
        if let minimum = property["minLength"]?.integerValue,
           let string = value.stringValue, string.count < minimum {
            throw AriaV2InvalidArgument(
                path: key,
                message: "Argument '\(key)' is shorter than its declared minimum.",
                correction: "Argument '\(key)' must be at least \(minimum) character\(minimum == 1 ? "" : "s")."
            ).jsonRPCError
        }
        if let maximum = property["maxLength"]?.integerValue,
           let string = value.stringValue, string.count > maximum {
            throw AriaV2InvalidArgument(
                path: key,
                message: "Argument '\(key)' is longer than its declared maximum.",
                correction: "Argument '\(key)' must be at most \(maximum) character\(maximum == 1 ? "" : "s")."
            ).jsonRPCError
        }
        if property["format"]?.stringValue == "uuid", let string = value.stringValue, UUID(uuidString: string) == nil {
            // Correction wording from AriaV2ArgumentDecoder.swift:191.
            throw AriaV2InvalidArgument(
                path: key,
                message: "Argument '\(key)' must be a UUID string.",
                correction: "Provide a valid UUID; accepted input casing is normalized on output."
            ).jsonRPCError
        }
    }

    private static func descriptor(
        identity: String,
        name: String,
        effect: AriaV2OperationEffect,
        description: String,
        properties: [String: JSONValue],
        required: [String],
        exactlyOneOf: [(String, String)] = []
    ) -> AriaV2OperationDescriptor {
        AriaV2OperationDescriptor(
            identity: .init(rawValue: identity),
            publicName: name,
            effect: effect,
            availability: .init(lanes: [.firstParty]),
            inputSchema: inputSchema(
                properties: properties,
                required: required,
                exactlyOneOf: exactlyOneOf
            ),
            projection: .init(
                outputSchema: outputSchema(tool: name, effect: effect),
                compactTextDescription: description
            ),
            help: .init(description: description)
        )
    }

    private static func outputSchema(tool: String, effect: AriaV2OperationEffect) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "surface_version": .object(["const": .string("v2")]),
                "tool": .object(["const": .string(tool)]),
                "data": .object(["type": .string("object"), "additionalProperties": .bool(true)]),
                "meta": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "effect": .object(["const": .string(effect.rawValue)]),
                    ]),
                    "required": .array([.string("effect")]),
                    "additionalProperties": .bool(true),
                ]),
            ]),
            "required": .array([.string("surface_version"), .string("tool"), .string("data"), .string("meta")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func stringSchema() -> JSONValue {
        .object(["type": .string("string")])
    }

    private static func booleanSchema() -> JSONValue {
        .object(["type": .string("boolean")])
    }

    private static func trueSchema() -> JSONValue {
        .object(["type": .string("boolean"), "const": .bool(true)])
    }

    private static func boundedStringSchema(minimum: Int, maximum: Int) -> JSONValue {
        .object(["type": .string("string"), "minLength": .integer(Int64(minimum)), "maxLength": .integer(Int64(maximum))])
    }

    private static func nonEmptyStringSchema() -> JSONValue {
        .object(["type": .string("string"), "minLength": .integer(1)])
    }

    private static func positiveIntegerSchema() -> JSONValue {
        .object(["type": .string("integer"), "minimum": .integer(1)])
    }

    private static func sensitivitySchema() -> JSONValue {
        enumSchema(["normal", "elevated", "restricted", "secret"])
    }

    private static func exportabilitySchema() -> JSONValue {
        enumSchema(["private", "public"])
    }

    private static func relationshipSchema() -> JSONValue {
        enumSchema(["blocks", "contradicts", "covers", "derives_from", "elaborates", "exemplifies", "extends", "precedes", "references", "refines", "relates", "responds_to", "supersedes", "supports", "validates"])
    }

    private static func inputSchema(
        properties: [String: JSONValue],
        required: [String],
        exactlyOneOf: [(String, String)]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ]
        let groups = exactlyOneOf.map { pair in
            JSONValue.array([
                .object(["required": .array([.string(pair.0)]), "not": .object(["required": .array([.string(pair.1)])])]),
                .object(["required": .array([.string(pair.1)]), "not": .object(["required": .array([.string(pair.0)])])]),
            ])
        }
        if groups.count == 1 {
            schema["oneOf"] = groups[0]
        } else if !groups.isEmpty {
            schema["allOf"] = .array(groups.map { .object(["oneOf": $0]) })
        }
        return .object(schema)
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    private static func dateTimeSchema() -> JSONValue {
        .object(["type": .string("string"), "format": .string("date-time")])
    }

    private static func uuidSchema() -> JSONValue {
        .object(["type": .string("string"), "format": .string("uuid")])
    }
}
/// The stable discovery record returned beside the existing MCP initialization
/// and `tools/list` exchanges.  It adds first-party contract identity without
/// changing either JSON-RPC envelope.
public struct FirstPartyProviderDiscovery: Sendable, Equatable {
    public let providerName: String
    public let contractVersion: String
    public let ariaSupportedVersion: String
    public let capabilities: [String]
    public let capabilityDigest: String

    public init(
        providerName: String,
        contractVersion: String,
        ariaSupportedVersion: String,
        capabilities: [String],
        capabilityDigest: String
    ) {
        self.providerName = providerName
        self.contractVersion = contractVersion
        self.ariaSupportedVersion = ariaSupportedVersion
        self.capabilities = capabilities
        self.capabilityDigest = capabilityDigest
    }

    public var jsonValue: JSONValue {
        .object([
            "provider": .string(providerName),
            "contract_version": .string(contractVersion),
            "aria_supported_version": .string(ariaSupportedVersion),
            "capabilities": .array(capabilities.map(JSONValue.string)),
            "capability_digest": .string(capabilityDigest),
        ])
    }
}
