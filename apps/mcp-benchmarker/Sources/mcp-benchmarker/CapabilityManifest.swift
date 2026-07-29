import Foundation

// CapabilityManifest.swift — the versioned capability-manifest layer (SPEC §13).
//
// A per-product capability manifest lets BM-01 benchmark any foreign MCP server
// without per-product code changes. The manifest is authored once (at
// tools/mcp-benchmarker/manifests/<product>.json when files exist) and resolved
// ONCE at startup into an in-memory DispatchTable that maps onto the shipped
// EndpointConfig.VerbMap shape.
//
// Performance-neutrality rule (SPEC §13.5, MANDATORY):
//   No JSON parsing, no argument-building, no technique lookup occurs inside the
//   timed window. The DispatchTable holds pre-compiled argument templates and
//   pre-resolved technique tags. The latency timer wraps ONLY the MCP wire
//   round-trip. The technique tag is attached to a sample AFTER the timer stops.
//
// Conformance-vector surface: this file's decode + resolve logic is deterministic
// and pure (no Date(), no randomness). The Rust leg must produce identical output
// for the same manifest JSON (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).

// MARK: - Validation errors

/// Errors raised when a capability manifest fails validation.
enum ManifestValidationError: Error, Sendable, CustomStringConvertible {
    /// A required field is absent or empty.
    case requiredFieldMissing(String)
    /// The provenance value is not one of the three recognized strings (SPEC §13.2).
    case unknownProvenance(String)
    /// A technique token is not in the controlled vocabulary (SPEC §13.4).
    case unknownTechnique(String)
    /// The technique list is empty (SPEC §13.7: technique MUST be non-empty).
    case emptyTechniqueList(callType: String)
    /// The manifest's major schema_version is not recognized; refuse rather than guess.
    case unknownSchemaVersion(Int)

    var description: String {
        switch self {
        case .requiredFieldMissing(let field):
            return "required field missing: \(field)"
        case .unknownProvenance(let value):
            return "unknown provenance '\(value)'; must be ground-truth-ours | vendor-declared | authored-from-public-docs"
        case .unknownTechnique(let token):
            return "unknown technique token '\(token)'; see SPEC §13.4 for the controlled vocabulary"
        case .emptyTechniqueList(let callType):
            return "technique list is empty for call type '\(callType)'; MUST be a non-empty list"
        case .unknownSchemaVersion(let v):
            return "unrecognized manifest schema_version \(v); refusing (do not guess)"
        }
    }
}

// MARK: - Controlled technique vocabulary (SPEC §13.4)

/// A technique token drawn from the controlled vocabulary (SPEC §13.4).
/// These are the only values permitted in a manifest's `technique` list.
/// The vocabulary is frozen here so the Rust leg can match it exactly.
enum TechniqueToken: String, Sendable, Codable, CaseIterable {
    case bm25             = "bm25"
    case vectorCosine     = "vector_cosine"
    case vectorHNSW       = "vector_hnsw"
    case rrf              = "rrf"
    case mmr              = "mmr"
    case graphTraversal   = "graph_traversal"
    case llmExtraction    = "llm_extraction"
    case embedding        = "embedding"
    case none_            = "none"
    case unknown          = "unknown"
}

// MARK: - Provenance (SPEC §13.2)

/// How a manifest's contents were obtained. Every technique-attributed report
/// number MUST surface this tag so readers do not mistake a claim for verified
/// fact (SPEC §10 honesty statement).
enum ManifestProvenance: String, Sendable, Codable {
    /// Authored by us for a product whose internals we know. Technique map is
    /// verified against our own code/specs. (e.g. contender, mootx01)
    case groundTruthOurs          = "ground-truth-ours"
    /// Supplied by the product's vendor. Authoritative as a claim; not
    /// independently verified by us.
    case vendorDeclared           = "vendor-declared"
    /// Reverse-engineered from the product's public docs. Best-effort; may be wrong.
    case authoredFromPublicDocs   = "authored-from-public-docs"
}

// MARK: - Product identity (SPEC §13)

struct ManifestProduct: Sendable {
    let id: String
    let displayName: String?
    let version: String?
    let homepage: String?
    let provenance: ManifestProvenance
    let provenanceNote: String?
}

// MARK: - Per-call-type entry (SPEC §13.3)

struct ManifestCallEntry: Sendable {
    let callType: String
    /// The foreign product's own tool name ("their lingo").
    let tool: String
    /// Argument role → this tool's argument key mapping (e.g. "content" → "text").
    let args: [String: String]
    /// Fixed arguments every call sends (may be empty).
    let constantArgs: [String: String]
    /// How the tool's response is shaped.
    let result: ResultFormat
    /// The mathematical technique(s) this call exercises (controlled vocabulary).
    let technique: [String]
    /// True when this call type has no equivalent on the other side (feeds
    /// comparison mode 2 — unmatched method, same outcome). Defaults false.
    let unmatched: Bool
    /// Optional pagination info (for list-type calls).
    let pagination: PaginationConfig?

    struct PaginationConfig: Sendable {
        let limitArg: String
        let offsetArg: String
        let pageSize: Int
    }
}

// MARK: - The dispatch table entry (startup-resolved; startup-only cost)

/// One entry in the startup-resolved dispatch table. Pre-compiled so the timed
/// window pays zero cost: no JSON parsing, no argument-building, no technique
/// lookup after startup (SPEC §13.5).
struct DispatchEntry: Sendable {
    /// The foreign product's tool name — what to put in `params.name`.
    let toolName: String
    /// Pre-compiled argument template: the constant args + arg-role bindings.
    /// At call time the caller plugs in the variable value (e.g. the query
    /// string) and sends. No argument-building inside the timed window.
    let constantArgs: [String: String]
    /// The argument key that receives the variable input (content for write,
    /// query text for query, etc.), mapped from the benchmarker's arg-role name.
    let argMapping: [String: String]
    /// The pre-resolved result format. No JSON parsing at call time.
    let resultFormat: ResultFormat
    /// The pre-resolved technique tag(s). Attached to a sample AFTER the timer
    /// stops — zero cost in the timed window (SPEC §13.5).
    let technique: [String]
    /// True when this call type has no equivalent on the other side.
    let unmatched: Bool
    /// The manifest provenance, surfaced next to any technique-attributed number
    /// in reports (SPEC §13.2, §10 honesty statement).
    let provenance: ManifestProvenance
}

/// The in-memory dispatch table resolved once at startup from a manifest.
/// Keys are call-type names (e.g. "write", "query", "think").
typealias ManifestDispatchTable = [String: DispatchEntry]

// MARK: - CapabilityManifest (the top-level type)

/// A decoded and validated capability manifest.
struct CapabilityManifest: Sendable {
    let schemaVersion: Int
    let product: ManifestProduct
    let transport: EndpointConfig.Transport
    let role: EndpointConfig.EndpointRole
    /// The per-call-type entries. Keyed by call type (e.g. "write", "query").
    let calls: [String: ManifestCallEntry]

    /// The current recognized schema major version. An unrecognized major version
    /// triggers a `.unknownSchemaVersion` error — refuse, do not guess.
    static let recognizedMajorVersions: Set<Int> = [1]

    // MARK: - Decode (startup cost only; not called inside any timed window)

    /// Decodes and validates a manifest from raw JSON data.
    /// Throws `ManifestValidationError` on any validation failure.
    static func decode(from data: Data) throws -> CapabilityManifest {
        guard let raw = try? JSONDecoder().decode(RawManifest.self, from: data) else {
            throw ManifestValidationError.requiredFieldMissing("(JSON decode failed — malformed manifest)")
        }
        // Schema-version gate (SPEC §13.7): refuse on unknown major version.
        guard recognizedMajorVersions.contains(raw.schema_version) else {
            throw ManifestValidationError.unknownSchemaVersion(raw.schema_version)
        }
        // Required product fields.
        guard !raw.product.id.isEmpty else {
            throw ManifestValidationError.requiredFieldMissing("product.id")
        }
        // Provenance validation (SPEC §13.2).
        guard let provenance = ManifestProvenance(rawValue: raw.product.provenance) else {
            throw ManifestValidationError.unknownProvenance(raw.product.provenance)
        }
        // Transport.
        let transport = try raw.transport.toTransport()
        // Role.
        let role = raw.role.map { EndpointConfig.EndpointRole(rawValue: $0) ?? .both } ?? .both
        // Calls: must have at least write + query (SPEC §13.7).
        guard let rawCalls = raw.calls, rawCalls["write"] != nil else {
            throw ManifestValidationError.requiredFieldMissing("calls.write")
        }
        guard rawCalls["query"] != nil else {
            throw ManifestValidationError.requiredFieldMissing("calls.query")
        }
        // Decode + validate each call entry.
        var calls: [String: ManifestCallEntry] = [:]
        for (callType, rawEntry) in rawCalls {
            if rawEntry.tool == nil { continue }  // skip empty/placeholder entries
            let entry = try validateCallEntry(rawEntry, callType: callType)
            calls[callType] = entry
        }
        let product = ManifestProduct(
            id: raw.product.id,
            displayName: raw.product.displayName,
            version: raw.product.version,
            homepage: raw.product.homepage,
            provenance: provenance,
            provenanceNote: raw.product.provenanceNote
        )
        return CapabilityManifest(
            schemaVersion: raw.schema_version,
            product: product,
            transport: transport,
            role: role,
            calls: calls
        )
    }

    // MARK: - Resolve (startup cost only; builds the dispatch table once)

    /// Resolves the manifest into an in-memory dispatch table. Called once at
    /// startup; the returned table is used for the duration of the run with
    /// zero per-call overhead (SPEC §13.5 performance-neutrality rule).
    func resolveDispatchTable() -> ManifestDispatchTable {
        var table: ManifestDispatchTable = [:]
        for (callType, entry) in calls {
            let dispatchEntry = DispatchEntry(
                toolName: entry.tool,
                constantArgs: entry.constantArgs,
                argMapping: entry.args,
                resultFormat: entry.result,
                technique: entry.technique,
                unmatched: entry.unmatched,
                provenance: product.provenance
            )
            table[callType] = dispatchEntry
        }
        return table
    }

    // MARK: - Private validation helpers

    private static func validateCallEntry(_ raw: RawCallEntry, callType: String) throws -> ManifestCallEntry {
        // technique MUST be a non-empty list (SPEC §13.7).
        guard let techniques = raw.technique, !techniques.isEmpty else {
            throw ManifestValidationError.emptyTechniqueList(callType: callType)
        }
        // Each technique token must be in the controlled vocabulary (SPEC §13.4).
        for token in techniques {
            guard TechniqueToken(rawValue: token) != nil else {
                throw ManifestValidationError.unknownTechnique(token)
            }
        }
        // result format.
        let resultFormat = try raw.result.toResultFormat()
        // Pagination (optional).
        let pagination: ManifestCallEntry.PaginationConfig? = raw.pagination.map {
            ManifestCallEntry.PaginationConfig(
                limitArg: $0.limitArg ?? "limit",
                offsetArg: $0.offsetArg ?? "offset",
                pageSize: $0.pageSize ?? 100
            )
        }
        return ManifestCallEntry(
            callType: callType,
            tool: raw.tool ?? callType,
            args: raw.args ?? [:],
            constantArgs: raw.constantArgs ?? [:],
            result: resultFormat,
            technique: techniques,
            unmatched: raw.unmatched ?? false,
            pagination: pagination
        )
    }
}

// MARK: - Raw JSON shapes (decode-only; startup cost)

private struct RawManifest: Decodable {
    let schema_version: Int
    let product: RawProduct
    let transport: RawTransport
    let role: String?
    let calls: [String: RawCallEntry]?

    struct RawProduct: Decodable {
        let id: String
        let displayName: String?
        let version: String?
        let homepage: String?
        let provenance: String
        let provenanceNote: String?
    }
}

private struct RawTransport: Decodable {
    let stdio: StdioPayload?
    let sse: SSEPayload?

    struct StdioPayload: Decodable { let command: String }
    struct SSEPayload: Decodable { let url: URL }

    func toTransport() throws -> EndpointConfig.Transport {
        if let s = stdio { return .stdio(command: s.command) }
        if let s = sse { return .sse(url: s.url) }
        throw ManifestValidationError.requiredFieldMissing("transport")
    }
}

private struct RawCallEntry: Decodable {
    let tool: String?
    let args: [String: String]?
    let constantArgs: [String: String]?
    let result: RawResult
    let technique: [String]?
    let unmatched: Bool?
    let pagination: RawPagination?

    struct RawResult: Decodable {
        let kind: String
        let idKey: String?
        let contentKey: String?
        let fetchContentKey: String?

        func toResultFormat() throws -> ResultFormat {
            switch kind {
            case "jsonObjects":
                guard let contentKey else {
                    throw ManifestValidationError.requiredFieldMissing("result.contentKey")
                }
                return .jsonObjects(idKey: idKey, contentKey: contentKey)
            case "mootText":
                return .mootText
            default:
                throw ManifestValidationError.requiredFieldMissing("result.kind=\(kind)")
            }
        }
    }

    struct RawPagination: Decodable {
        let limitArg: String?
        let offsetArg: String?
        let pageSize: Int?
    }
}
