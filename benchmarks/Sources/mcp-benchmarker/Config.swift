import Foundation

// Config.swift — JSON config schema and loader.
//
// The benchmarker is engine-agnostic: it talks to two MCP servers whose
// tool names it does not know in advance. The `verbMap` on each endpoint
// is the decoupling layer — it tells the tool which of THIS server's MCP
// tools mean write / query / list, so the tool is never hardcoded to any
// specific server's tool names.
//
// Config is JSON, decoded via Foundation Codable. JSON (not YAML) keeps the
// core config layer dependency-free; a YAML parser would require an external package.
// (The package does declare swift-subprocess for stdio process management.)

/// Errors surfaced while loading or validating a benchmarker config.
/// `missingField` carries the dotted path of the absent required field
/// (for example `verbMap.write`) so failures are diagnosable at load time
/// rather than at first use.
public enum ConfigError: Error, Sendable, Equatable {
    case missingField(String)
    case invalidTransport
}

/// Optional authentication for a remote endpoint. Both fields are optional
/// so a local stdio server (which needs no auth) decodes cleanly.
///
/// `header` has a dual role: when absent, the token is sent as
/// `Authorization: Bearer <token>`; when present, the token is sent verbatim
/// (no `Bearer` prefix) under the named header. So setting
/// `header: "Authorization"` yields `Authorization: <token>` — NOT
/// `Authorization: Bearer <token>`. Leave `header` unset for standard
/// bearer auth; set it only when the server expects a raw-value header such
/// as `X-API-Key`.
public struct AuthConfig: Codable, Sendable, Equatable {
    public let token: String?
    public let header: String?

    public init(token: String?, header: String?) {
        self.token = token
        self.header = header
    }
}

/// How a server encodes the result of a tool call. The benchmarker is
/// engine-agnostic, but the two real servers it targets return wildly
/// different shapes, so the shape is named in config rather than guessed:
///
///   - `jsonObjects`: an array of objects (under `structuredContent`, or in
///     a `text` block parsed as JSON, or under a `results`/`items` key). The
///     id and content fields are NOT assumed to be named `id`/`content` —
///     `idKey` and `contentKey` name them. An external paginating server might
///     return `{ "drawers": [ { "drawer_id", "content_preview", ... } ] }`,
///     mapping with `idKey: "drawer_id", contentKey: "content_preview"`. A
///     search-only server might return `{ "results": [ { "text", ... } ] }`
///     with NO stable id, mapping with `idKey: nil, contentKey: "text"`.
///   - `mootText`: MOOTx01's plain-text MCP results. A search returns
///     `found N memory(s)` then one ranked line per hit, each
///     `<UUID>  [location]  <content>`. A write returns
///     `filed memory <UUID>` (the target-assigned UUID). No JSON to parse.
public enum ResultFormat: Codable, Sendable, Equatable {
    /// JSON objects; `idKey` names the id field (nil when the server returns
    /// no stable id, e.g. a search-only result), `contentKey` names the
    /// content field. When the server nests the array under a key, the parser
    /// also looks under `results` / `items` and any single array-valued key.
    case jsonObjects(idKey: String?, contentKey: String)
    /// MOOTx01 plain-text results (`found N memory(s)` lines for search,
    /// `filed memory <UUID>` for write). UUID is the leading token per line.
    case mootText
    /// MOOTx01 ARIA v2 structured results. The parser reads the typed
    /// `structuredContent` envelope and falls back to text blocks for
    /// diagnostics. Response shapes by operation:
    ///   - moot_memory_search  → data.results[].{memory_id, excerpt}
    ///   - moot_recall_*       → data.results[].{id, bestSpan}
    ///   - moot_file_memory    → data.memory_id  (write receipt)
    ///   - moot_memory_get     → data.memories[].{memory_id, content}
    ///   - moot_memory_list    → data.memories[].{memory_id}
    case mootV2

    private enum CodingKeys: String, CodingKey { case kind, idKey, contentKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "jsonObjects":
            self = .jsonObjects(
                idKey: try c.decodeIfPresent(String.self, forKey: .idKey),
                // contentKey is required for jsonObjects — without it the
                // transfer engine cannot read an item's content.
                contentKey: try c.decode(String.self, forKey: .contentKey))
        case "mootText":
            self = .mootText
        case "mootV2":
            self = .mootV2
        default:
            throw ConfigError.missingField("resultFormat.kind=\(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .jsonObjects(idKey, contentKey):
            try c.encode("jsonObjects", forKey: .kind)
            try c.encodeIfPresent(idKey, forKey: .idKey)
            try c.encode(contentKey, forKey: .contentKey)
        case .mootText:
            try c.encode("mootText", forKey: .kind)
        case .mootV2:
            try c.encode("mootV2", forKey: .kind)
        }
    }
}

/// One MCP endpoint the benchmarker talks to. Engine-agnostic: the verbMap
/// tells the tool which of THIS server's MCP tools mean write/query/list,
/// so the tool is not hardcoded to any specific server's tool names.
public struct EndpointConfig: Codable, Sendable, Equatable {
    public let name: String
    public let transport: Transport
    public let auth: AuthConfig?
    public let verbMap: VerbMap
    public let role: EndpointRole

    public init(name: String, transport: Transport, auth: AuthConfig?,
                verbMap: VerbMap, role: EndpointRole) {
        self.name = name
        self.transport = transport
        self.auth = auth
        self.verbMap = verbMap
        self.role = role
    }

    /// How the tool reaches this server. Encoded as a single-key object —
    /// `{ "stdio": { "command": ... } }` or `{ "sse": { "url": ... } }` —
    /// so the JSON reads as a tagged union rather than a flat field set.
    public enum Transport: Codable, Sendable, Equatable {
        case stdio(command: String)   // launch a local MCP server process
        case sse(url: URL)            // connect to a remote MCP server over SSE

        private enum CodingKeys: String, CodingKey { case stdio, sse }
        private struct StdioPayload: Codable { let command: String }
        private struct SSEPayload: Codable { let url: URL }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try c.decodeIfPresent(StdioPayload.self, forKey: .stdio) {
                self = .stdio(command: s.command)
            } else if let s = try c.decodeIfPresent(SSEPayload.self, forKey: .sse) {
                self = .sse(url: s.url)
            } else {
                // Neither transport key present — not a transport we know.
                throw ConfigError.invalidTransport
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .stdio(let command):
                try c.encode(StdioPayload(command: command), forKey: .stdio)
            case .sse(let url):
                try c.encode(SSEPayload(url: url), forKey: .sse)
            }
        }
    }

    /// Maps the three benchmarker verbs onto this server's MCP tool names AND
    /// onto the argument key names + result shape each verb uses. `write` and
    /// `query` are required; `list` is optional because some targets expose no
    /// enumerate-all tool (the source needs `list` to drive a transfer, but a
    /// target may only need write + query).
    ///
    /// The argument keys exist because tool NAMES alone are not enough to drive
    /// a live call: `moot_file_memory` needs `{ content, location }` (not
    /// `{ id, content }`), `moot_memory_search` needs `{ query }`. The defaults
    /// match the MOOTx01 argument names so a minimal config still runs live;
    /// override only when a server names its arguments differently.
    public struct VerbMap: Codable, Sendable, Equatable {
        public let write: String             // this server's "store an entry" tool
        public let query: String             // this server's "search/recall" tool
        public let list: String?             // this server's "enumerate all" tool, if any
        /// This server's "fetch one full entry by id" tool, if any. The `list`
        /// verb on a paginating source may return TRUNCATED previews per item,
        /// not full content; a faithful transfer must fetch the full content of
        /// each item by id before writing it. nil when `list` already returns
        /// full content (no separate fetch needed).
        public let fetch: String?

        // MARK: Argument key names (per-verb argument construction)

        /// The argument key under which the write tool receives the entry
        /// content. Default `content` (MOOTx01 `moot_file_memory`).
        public let contentArg: String
        /// The argument key under which the query tool receives the search
        /// text. Default `query` (both servers).
        public let queryArg: String
        /// The argument key under which the `fetch` tool receives the item id.
        /// Default `drawer_id` (a paginating server that exposes a per-id fetch).
        public let fetchIDArg: String
        /// The key holding full content in a `fetch` result. A per-id fetch
        /// typically returns a single object with full content under `content`
        /// (distinct from the truncated `content_preview` a `list` returns).
        /// Default `content`.
        public let fetchContentKey: String
        /// The argument key under which `list` receives the page size.
        /// Default `limit`.
        public let listLimitArg: String
        /// The argument key under which `list` receives the page offset.
        /// Default `offset`.
        public let listOffsetArg: String
        /// Page size for paginated enumeration. Default 100.
        /// The transfer loops `offset` by this until a short/empty page.
        public let listPageSize: Int
        /// Constant arguments every write call sends in addition to the
        /// content. Different servers require different fixed write context:
        /// MOOTx01's `moot_file_memory` requires one (`location`). A map (not
        /// a single key) covers any combination without per-server special
        /// cases. Default: `{ "location": "import/external-source" }` — the
        /// MOOTx01 import location for content migrated from an external source.
        /// Set to `{}` for a write tool that needs only content.
        public let constantArgs: [String: String]

        // MARK: Dense recall (token-efficiency arm)

        /// Optional dense-recall query tool name (e.g. `moot_recall_distilled`).
        /// When non-nil, the two-arm token-efficiency benchmark can drive the
        /// dense recall path through this same VerbMap rather than needing a
        /// separate config block. nil = no dense query configured (single-arm).
        public let denseQuery: String?
        /// Constant arguments for the dense query tool. Separate from
        /// `constantArgs` because the dense tool may have different required
        /// fields (e.g. `moot_recall_distilled` does not need `location`).
        /// Default: empty (no constant args beyond the query text itself).
        public let denseQueryConstantArgs: [String: String]

        // MARK: Result shape

        /// How this server encodes the result of `query`/`list` (and how a
        /// write response carries its assigned id). Default: `jsonObjects`
        /// with `idKey: "id", contentKey: "content"` — the conventional shape
        /// the tool assumed before live shapes were known. Real configs name
        /// the actual shape (e.g. `jsonObjects` with custom id/content keys
        /// for an external server, or `mootText` for MOOTx01).
        public let resultFormat: ResultFormat

        public init(write: String,
             query: String,
             list: String?,
             fetch: String? = nil,
             contentArg: String = "content",
             queryArg: String = "query",
             fetchIDArg: String = "drawer_id",
             fetchContentKey: String = "content",
             listLimitArg: String = "limit",
             listOffsetArg: String = "offset",
             listPageSize: Int = 100,
             constantArgs: [String: String] = ["location": "import/external-source"],
             denseQuery: String? = nil,
             denseQueryConstantArgs: [String: String] = [:],
             resultFormat: ResultFormat = .jsonObjects(idKey: "id", contentKey: "content")) {
            self.write = write
            self.query = query
            self.list = list
            self.fetch = fetch
            self.contentArg = contentArg
            self.queryArg = queryArg
            self.fetchIDArg = fetchIDArg
            self.fetchContentKey = fetchContentKey
            self.listLimitArg = listLimitArg
            self.listOffsetArg = listOffsetArg
            self.listPageSize = listPageSize
            self.constantArgs = constantArgs
            self.denseQuery = denseQuery
            self.denseQueryConstantArgs = denseQueryConstantArgs
            self.resultFormat = resultFormat
        }

        private enum CodingKeys: String, CodingKey {
            case write, query, list, fetch
            case contentArg, queryArg, fetchIDArg, fetchContentKey
            case listLimitArg, listOffsetArg, listPageSize
            case constantArgs
            case denseQuery, denseQueryConstantArgs
            case resultFormat
        }

        // Custom decoder so an absent required verb surfaces as
        // ConfigError.missingField at load time, not as a generic
        // DecodingError.keyNotFound at first use. The argument-key and
        // result-format fields default when absent so a terse config still
        // decodes and runs live against the MOOTx01 defaults.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let write = try c.decodeIfPresent(String.self, forKey: .write) else {
                throw ConfigError.missingField("verbMap.write")
            }
            guard let query = try c.decodeIfPresent(String.self, forKey: .query) else {
                throw ConfigError.missingField("verbMap.query")
            }
            self.write = write
            self.query = query
            self.list = try c.decodeIfPresent(String.self, forKey: .list)
            self.fetch = try c.decodeIfPresent(String.self, forKey: .fetch)
            self.contentArg = try c.decodeIfPresent(String.self, forKey: .contentArg) ?? "content"
            self.queryArg = try c.decodeIfPresent(String.self, forKey: .queryArg) ?? "query"
            self.fetchIDArg = try c.decodeIfPresent(String.self, forKey: .fetchIDArg) ?? "drawer_id"
            self.fetchContentKey = try c.decodeIfPresent(String.self, forKey: .fetchContentKey) ?? "content"
            self.listLimitArg = try c.decodeIfPresent(String.self, forKey: .listLimitArg) ?? "limit"
            self.listOffsetArg = try c.decodeIfPresent(String.self, forKey: .listOffsetArg) ?? "offset"
            self.listPageSize = try c.decodeIfPresent(Int.self, forKey: .listPageSize) ?? 100
            // constantArgs defaults to the MOOTx01 import case when absent; an
            // explicit `{}` sends no constant write args (a write tool needing
            // only content); an explicit map is sent verbatim.
            self.constantArgs = try c.decodeIfPresent([String: String].self, forKey: .constantArgs)
                ?? ["location": "import/external-source"]
            // denseQuery fields are optional with safe nil/empty defaults — existing
            // configs decode cleanly without them.
            self.denseQuery = try c.decodeIfPresent(String.self, forKey: .denseQuery)
            self.denseQueryConstantArgs = try c.decodeIfPresent(
                [String: String].self, forKey: .denseQueryConstantArgs) ?? [:]
            self.resultFormat = try c.decodeIfPresent(ResultFormat.self, forKey: .resultFormat)
                ?? .jsonObjects(idKey: "id", contentKey: "content")
        }
    }

    public enum EndpointRole: String, Codable, Sendable, Equatable { case source, target, both }
}

/// Top-level config: the source and target endpoints.
public struct BenchmarkerConfig: Codable, Sendable, Equatable {
    public let source: EndpointConfig
    public let target: EndpointConfig

    public init(source: EndpointConfig, target: EndpointConfig) {
        self.source = source
        self.target = target
    }

    /// Decodes config.json. Throws ConfigError.missingField when a required
    /// verbMap entry is absent — caught at load, not at first use.
    public static func load(from url: URL) throws -> BenchmarkerConfig {
        let data = try Data(contentsOf: url)
        // A custom init(from:) on VerbMap may throw ConfigError; JSONDecoder
        // propagates such errors unchanged, so callers see ConfigError, not a
        // wrapped DecodingError.
        return try JSONDecoder().decode(BenchmarkerConfig.self, from: data)
    }
}
