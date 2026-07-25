import Foundation

// WorkPacket — schema v1.
//
// A durable record of agentic objective, sources, claims, uncertainties,
// next steps, provenance, and lineage links. Stored as the content of a
// LocusKit drawer (kind `.structuredJSON`, room `"work-packets"`).
//
// Forward compatibility: any JSON key not recognised by the v1 decoder is
// captured in `additionalFields` and re-encoded verbatim, so a v1 reader
// round-tripping a v2 packet does not silently drop future fields.

// MARK: - WorkPacket

/// Durable record of a unit of agentic work.
///
/// Wire format: JSON produced by `JSONEncoder` with `.iso8601` date strategy.
/// The `schemaVersion` field drives compatibility guards — callers should
/// surface a warning when reading a packet with `schemaVersion` above
/// `WorkPacket.currentSchemaVersion`.
public struct WorkPacket: Sendable, Equatable {

    /// The schema version encoded in this packet. Always
    /// `WorkPacket.currentSchemaVersion` for packets produced by this kit.
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int

    /// Stable identifier for this packet. UUID string; issued at creation and
    /// preserved across mutations. NOT the estate drawer ID — the estate assigns
    /// its own UUID when the packet is stored via `WorkPacketStore`. Use the
    /// drawer ID returned by `store()` for retrieval and for `LineageLink.targetPacketID`.
    public let id: String

    /// What this unit of work is trying to achieve.
    public let objective: String

    /// Evidence and reference material the agent consulted.
    public let sources: [WorkPacketSource]

    /// Conclusions the agent reached, each with a confidence score and
    /// pointers to supporting sources.
    public let claims: [WorkPacketClaim]

    /// Known unknowns the agent identified but did not resolve.
    public let uncertainties: [String]

    /// Recommended follow-on actions.
    public let nextSteps: [String]

    /// Capture-time provenance: which model, which agent, when.
    public let provenance: WorkPacketProvenance

    /// Typed links to prior packets that this packet derives from or responds to.
    /// These links are also mirrored as LocusKit tunnels in the estate for
    /// graph traversal; the JSON embedding is the self-contained source of truth.
    public let lineageLinks: [LineageLink]

    // Unknown JSON keys from future schema versions, preserved verbatim
    // so round-trip encode does not lose forward-compat fields.
    // Not public API; exposed for testing only.
    var additionalFields: [String: JSONValue]

    public init(
        id: String = UUID().uuidString,
        schemaVersion: Int = WorkPacket.currentSchemaVersion,
        objective: String,
        sources: [WorkPacketSource] = [],
        claims: [WorkPacketClaim] = [],
        uncertainties: [String] = [],
        nextSteps: [String] = [],
        provenance: WorkPacketProvenance,
        lineageLinks: [LineageLink] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.objective = objective
        self.sources = sources
        self.claims = claims
        self.uncertainties = uncertainties
        self.nextSteps = nextSteps
        self.provenance = provenance
        self.lineageLinks = lineageLinks
        self.additionalFields = [:]
    }
}

// MARK: - WorkPacket + Codable

extension WorkPacket: Codable {

    // Known coding keys for v1. Any key not in this set lands in additionalFields.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case objective
        case sources
        case claims
        case uncertainties
        case nextSteps
        case provenance
        case lineageLinks
    }

    // Static literal of all v1 CodingKeys string values. Avoids the CaseIterable
    // extension pattern, which cannot reference a private nested enum from
    // outside its declaring extension scope.
    private static let knownCodingKeys: Set<String> = [
        "schemaVersion", "id", "objective", "sources", "claims",
        "uncertainties", "nextSteps", "provenance", "lineageLinks"
    ]

    public init(from decoder: any Decoder) throws {
        // Decode all top-level keys into a [String: JSONValue] first so
        // unknown keys are captured verbatim.
        let rawContainer = try decoder.container(keyedBy: RawKey.self)
        var extra: [String: JSONValue] = [:]
        let knownKeys = WorkPacket.knownCodingKeys
        for key in rawContainer.allKeys where !knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try rawContainer.decode(JSONValue.self, forKey: key)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.id = try container.decode(String.self, forKey: .id)
        self.objective = try container.decode(String.self, forKey: .objective)
        self.sources = try container.decodeIfPresent([WorkPacketSource].self, forKey: .sources) ?? []
        self.claims = try container.decodeIfPresent([WorkPacketClaim].self, forKey: .claims) ?? []
        self.uncertainties = try container.decodeIfPresent([String].self, forKey: .uncertainties) ?? []
        self.nextSteps = try container.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        self.provenance = try container.decode(WorkPacketProvenance.self, forKey: .provenance)
        self.lineageLinks = try container.decodeIfPresent([LineageLink].self, forKey: .lineageLinks) ?? []
        self.additionalFields = extra
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RawKey.self)
        try container.encode(schemaVersion, forKey: RawKey("schemaVersion"))
        try container.encode(id, forKey: RawKey("id"))
        try container.encode(objective, forKey: RawKey("objective"))
        try container.encode(sources, forKey: RawKey("sources"))
        try container.encode(claims, forKey: RawKey("claims"))
        try container.encode(uncertainties, forKey: RawKey("uncertainties"))
        try container.encode(nextSteps, forKey: RawKey("nextSteps"))
        try container.encode(provenance, forKey: RawKey("provenance"))
        try container.encode(lineageLinks, forKey: RawKey("lineageLinks"))
        for (key, value) in additionalFields {
            try container.encode(value, forKey: RawKey(key))
        }
    }

    // Erasure key used for both the unknown-field scan and the encode pass,
    // so both containers share a single CodingKey type.
    private struct RawKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

// MARK: - WorkPacketSource

/// A source or piece of evidence the agent consulted while producing a packet.
public struct WorkPacketSource: Codable, Sendable, Equatable {

    /// Stable identifier for this source within the packet.
    public let id: String

    /// Human-readable description of the source.
    public let description: String

    /// Optional URI or path reference.
    public let uri: String?

    /// Open-ended kind tag (e.g. `"drawer"`, `"web"`, `"file"`, `"citation"`).
    /// String rather than a closed enum to avoid schema churn as new source
    /// kinds emerge.
    public let kind: String

    public init(
        id: String = UUID().uuidString,
        description: String,
        uri: String? = nil,
        kind: String = "drawer"
    ) {
        self.id = id
        self.description = description
        self.uri = uri
        self.kind = kind
    }
}

// MARK: - WorkPacketClaim

/// A conclusion the agent reached, with supporting evidence and confidence.
public struct WorkPacketClaim: Codable, Sendable, Equatable {

    /// Stable identifier for this claim within the packet.
    public let id: String

    /// The claim text.
    public let statement: String

    /// Agent-assessed confidence, 0.0 (no confidence) to 1.0 (certain).
    public let confidence: Double

    /// IDs of WorkPacketSources that support this claim.
    public let supportingSourceIDs: [String]

    public init(
        id: String = UUID().uuidString,
        statement: String,
        confidence: Double,
        supportingSourceIDs: [String] = []
    ) {
        self.id = id
        self.statement = statement
        self.confidence = confidence
        self.supportingSourceIDs = supportingSourceIDs
    }
}

// MARK: - WorkPacketProvenance

/// Capture-time provenance for a work packet.
public struct WorkPacketProvenance: Codable, Sendable, Equatable {

    /// Identifier of the model that produced this packet (e.g. model name/version).
    public let model: String

    /// Identifier of the agent process that filed this packet.
    public let agent: String

    /// When the packet was originally created.
    public let createdAt: Date

    /// When the packet was most recently updated.
    public let updatedAt: Date

    public init(
        model: String,
        agent: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.model = model
        self.agent = agent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - LineageLink

/// A typed link from this packet to an antecedent packet.
public struct LineageLink: Codable, Sendable, Equatable {

    /// Relationship kind.
    public let kind: LineageLinkKind

    /// The estate-assigned drawer ID of the target (antecedent) packet, as
    /// returned by `WorkPacketStore.store()`. NOT the target packet's own `id`
    /// field — the estate assigns a separate UUID at capture time.
    public let targetPacketID: String

    public init(kind: LineageLinkKind, targetPacketID: String) {
        self.kind = kind
        self.targetPacketID = targetPacketID
    }
}

// MARK: - LineageLinkKind

/// Typed vocabulary for lineage relationships between work packets.
/// Maps to LocusKit `TunnelKind.derivesFrom` and `TunnelKind.respondsTo`.
public enum LineageLinkKind: String, Codable, Sendable, Equatable {
    /// This packet is derived from the target (built on top of its conclusions).
    case derivesFrom
    /// This packet responds to the target (addresses it, contradicts it, etc.).
    case respondsTo
}
