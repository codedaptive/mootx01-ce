import AriaMCPWire

/// A stable internal identity for a v2 operation.  It deliberately differs
/// from the public tool name so an operation can retain its policy identity
/// across a presentation change.
public struct AriaV2OperationIdentity: Sendable, Hashable, Equatable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A v2 operation identity must not be empty.")
        self.rawValue = rawValue
    }
}

/// A named capability that can be supplied by the selected build.
public struct AriaV2Capability: Sendable, Hashable, Equatable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A v2 capability must not be empty.")
        self.rawValue = rawValue
    }
}

/// A visibility lane evaluated while constructing the effective catalog.
public struct AriaV2VisibilityLane: Sendable, Hashable, Equatable, RawRepresentable {
    public static let `public` = AriaV2VisibilityLane(rawValue: "public")
    public static let firstParty = AriaV2VisibilityLane(rawValue: "first_party")

    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A v2 visibility lane must not be empty.")
        self.rawValue = rawValue
    }
}

/// The explicit inputs used to choose the visible v2 operation set.
public struct AriaV2RegistryInputs: Sendable, Equatable {
    public let buildID: String
    public let lane: AriaV2VisibilityLane
    public let capabilities: Set<AriaV2Capability>

    public init(
        buildID: String,
        lane: AriaV2VisibilityLane,
        capabilities: Set<AriaV2Capability>
    ) {
        self.buildID = buildID
        self.lane = lane
        self.capabilities = capabilities
    }
}

/// Preconditions owned by an operation descriptor.  An operation is absent
/// from the effective registry when any of these conditions is unmet.
public struct AriaV2OperationAvailability: Sendable, Equatable {
    /// An empty set accepts every build identifier.
    public let buildIDs: Set<String>
    /// An empty set accepts every visibility lane.
    public let lanes: Set<AriaV2VisibilityLane>
    public let requiredCapabilities: Set<AriaV2Capability>

    public init(
        buildIDs: Set<String> = [],
        lanes: Set<AriaV2VisibilityLane> = [],
        requiredCapabilities: Set<AriaV2Capability> = []
    ) {
        self.buildIDs = buildIDs
        self.lanes = lanes
        self.requiredCapabilities = requiredCapabilities
    }

    public func isSatisfied(by inputs: AriaV2RegistryInputs) -> Bool {
        (buildIDs.isEmpty || buildIDs.contains(inputs.buildID))
            && (lanes.isEmpty || lanes.contains(inputs.lane))
            && requiredCapabilities.isSubset(of: inputs.capabilities)
    }
}

/// The two public consequence categories a v2 call reports in metadata.
public enum AriaV2OperationEffect: String, Sendable, Equatable, CaseIterable {
    case read
    case write
}

/// Internal admission and authorization policy. Public metadata remains the
/// contract's two-value read/write vocabulary.
enum AriaV2OperationAuthorizationPolicy: Sendable, Equatable {
    case inspection
    case mutation
}

extension AriaV2OperationEffect {
    var authorizationPolicy: AriaV2OperationAuthorizationPolicy {
        switch self {
        case .read:
            return .inspection
        case .write:
            return .mutation
        }
    }
}

/// Projection details owned with the operation definition rather than inferred
/// from a runner's text response.
public struct AriaV2OperationProjection: Sendable, Equatable {
    public let outputSchema: JSONValue
    public let compactTextDescription: String

    public init(outputSchema: JSONValue, compactTextDescription: String) {
        self.outputSchema = outputSchema
        self.compactTextDescription = compactTextDescription
    }
}

/// Help metadata owned with a callable operation.
public struct AriaV2OperationHelp: Sendable, Equatable {
    public let description: String
    public let intents: [String]
    public let example: JSONValue?
    public let prerequisites: [String]

    public init(
        description: String,
        intents: [String] = [],
        example: JSONValue? = nil,
        prerequisites: [String] = []
    ) {
        self.description = description
        self.intents = intents
        self.example = example
        self.prerequisites = prerequisites
    }
}

/// The complete v2 definition for one callable operation.  This foundation
/// carries no rows; the shared fixture-backed census supplies them later.
public struct AriaV2OperationDescriptor: Sendable, Equatable {
    public let identity: AriaV2OperationIdentity
    public let publicName: String
    public let effect: AriaV2OperationEffect
    public let availability: AriaV2OperationAvailability
    public let inputSchema: JSONValue
    public let projection: AriaV2OperationProjection
    public let help: AriaV2OperationHelp
    public let provenance: ToolProvenance

    public init(
        identity: AriaV2OperationIdentity,
        publicName: String,
        effect: AriaV2OperationEffect,
        availability: AriaV2OperationAvailability,
        inputSchema: JSONValue,
        projection: AriaV2OperationProjection,
        help: AriaV2OperationHelp,
        provenance: ToolProvenance = .interface
    ) {
        precondition(!publicName.isEmpty, "A v2 operation public name must not be empty.")
        self.identity = identity
        self.publicName = publicName
        self.effect = effect
        self.availability = availability
        self.inputSchema = inputSchema
        self.projection = projection
        self.help = help
        self.provenance = provenance
    }

    public func projectedTool() -> ProjectedTool {
        ProjectedTool(
            name: publicName,
            description: help.description,
            inputSchema: inputSchema,
            provenance: provenance,
            outputSchema: projection.outputSchema,
            annotations: wireAnnotations
        )
    }

    private var wireAnnotations: JSONValue {
        let additiveWrites: Set<String> = [
            "file_memory", "link_memories", "file_fact", "write_journal",
            "file_dataset", "file_packet", "propose_contradictions",
        ]
        let openWorldOperations: Set<String> = [
            "palace_import", "json_import", "vault_export", "vault_import",
            "vault_reconcile",
        ]
        return .object([
            "readOnlyHint": .bool(effect == .read),
            "destructiveHint": .bool(effect == .write && !additiveWrites.contains(identity.rawValue)),
            "openWorldHint": .bool(openWorldOperations.contains(identity.rawValue)),
        ])
    }
}

public enum AriaV2RegistryError: Error, Equatable {
    case duplicateIdentity(AriaV2OperationIdentity)
    case duplicatePublicName(String)
}

/// The selected, callable subset for one explicit build/lane/capability
/// context.  This type does not read the environment and cannot manufacture
/// catalog entries, so unavailable operations cannot be advertised through it.
public struct AriaV2EffectiveRegistry: Sendable, Equatable {
    public let inputs: AriaV2RegistryInputs
    public let operations: [AriaV2OperationDescriptor]

    public init(
        descriptors: [AriaV2OperationDescriptor],
        inputs: AriaV2RegistryInputs
    ) throws {
        var identities = Set<AriaV2OperationIdentity>()
        var publicNames = Set<String>()
        for descriptor in descriptors {
            guard identities.insert(descriptor.identity).inserted else {
                throw AriaV2RegistryError.duplicateIdentity(descriptor.identity)
            }
            guard publicNames.insert(descriptor.publicName).inserted else {
                throw AriaV2RegistryError.duplicatePublicName(descriptor.publicName)
            }
        }

        self.inputs = inputs
        self.operations = descriptors
            .filter { $0.availability.isSatisfied(by: inputs) }
            .sorted { $0.publicName < $1.publicName }
    }

    public func operation(named publicName: String) -> AriaV2OperationDescriptor? {
        operations.first { $0.publicName == publicName }
    }

    public var projectedTools: [ProjectedTool] {
        operations.map { $0.projectedTool() }
    }
}
