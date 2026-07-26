import Foundation

// Config.swift — JSON config schema and loader.
//
// The benchmarker is engine-agnostic: it talks to two MCP servers whose
// tool names it does not know in advance. The `verbMap` on each endpoint
// is the decoupling layer — it tells the tool which of THIS server's MCP
// tools mean write / query / list, so the tool is never hardcoded to
// MemPalace's or MOOTx01's specific tool names.
//
// Config is JSON, decoded via Foundation Codable. JSON (not YAML) keeps the
// core config layer dependency-free; a YAML parser would require an external package.
// (The package does declare swift-subprocess for stdio process management.)

/// Errors surfaced while loading or validating a benchmarker config.
/// `missingField` carries the dotted path of the absent required field
/// (for example `verbMap.write`) so failures are diagnosable at load time
/// rather than at first use.
enum ConfigError: Error, Sendable, Equatable {
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
struct AuthConfig: Codable, Sendable, Equatable {
    let token: String?
    let header: String?
}

/// How a server encodes the result of a tool call. The benchmarker is
/// engine-agnostic, but the two real servers it targets return wildly
/// different shapes, so the shape is named in config rather than guessed:
///
///   - `jsonObjects`: an array of objects (under `structuredContent`, or in
///     a `text` block parsed as JSON, or under a `results`/`items` key). The
///     id and content fields are NOT assumed to be named `id`/`content` —
///     `idKey` and `contentKey` name them. MemPalace's `list_drawers`
///     returns `{ "drawers": [ { "drawer_id", "content_preview", ... } ] }`,
///     so it maps with `idKey: "drawer_id", contentKey: "content_preview"`.
///     MemPalace's `search` returns `{ "results": [ { "text", ... } ] }`
///     with NO stable id, so it maps with `idKey: nil, contentKey: "text"`.
///   - `mootText`: MOOTx01's plain-text MCP results. A search returns
///     `found N memory(s)` then one ranked line per hit, each
///     `<UUID>  [location]  <content>`. A write returns
///     `filed memory <UUID>` (the target-assigned UUID). No JSON to parse.
enum ResultFormat: Codable, Sendable, Equatable {
    /// JSON objects; `idKey` names the id field (nil when the server returns
    /// no stable id, e.g. MemPalace search), `contentKey` names the content
    /// field. When the server nests the array under a key, the parser also
    /// looks under `results` / `items` and any single array-valued key.
    case jsonObjects(idKey: String?, contentKey: String)
    /// MOOTx01 plain-text results (`found N memory(s)` lines for search,
    /// `filed memory <UUID>` for write). UUID is the leading token per line.
    case mootText

    private enum CodingKeys: String, CodingKey { case kind, idKey, contentKey }

    init(from decoder: Decoder) throws {
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
        default:
            throw ConfigError.missingField("resultFormat.kind=\(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .jsonObjects(idKey, contentKey):
            try c.encode("jsonObjects", forKey: .kind)
            try c.encodeIfPresent(idKey, forKey: .idKey)
            try c.encode(contentKey, forKey: .contentKey)
        case .mootText:
            try c.encode("mootText", forKey: .kind)
        }
    }
}

/// One MCP endpoint the benchmarker talks to. Engine-agnostic: the verbMap
/// tells the tool which of THIS server's MCP tools mean write/query/list,
/// so the tool is not hardcoded to MemPalace's or MOOTx01's tool names.
struct EndpointConfig: Codable, Sendable, Equatable {
    let name: String
    let transport: Transport
    let auth: AuthConfig?
    let verbMap: VerbMap
    let role: EndpointRole

    /// How the tool reaches this server. Encoded as a single-key object —
    /// `{ "stdio": { "command": ... } }` or `{ "sse": { "url": ... } }` —
    /// so the JSON reads as a tagged union rather than a flat field set.
    enum Transport: Codable, Sendable, Equatable {
        case stdio(command: String)   // launch a local MCP server process
        case sse(url: URL)            // connect to a remote MCP server over SSE

        private enum CodingKeys: String, CodingKey { case stdio, sse }
        private struct StdioPayload: Codable { let command: String }
        private struct SSEPayload: Codable { let url: URL }

        init(from decoder: Decoder) throws {
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

        func encode(to encoder: Encoder) throws {
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
    /// `{ id, content }`), `moot_memory_search` needs `{ query }`, and
    /// `mempalace_search` needs `{ query }`. The defaults match the MOOTx01/
    /// MemPalace argument names so a minimal config still runs live; override
    /// only when a server names its arguments differently.
    struct VerbMap: Codable, Sendable, Equatable {
        let write: String             // this server's "store an entry" tool
        let query: String             // this server's "search/recall" tool
        let list: String?             // this server's "enumerate all" tool, if any
        /// This server's "fetch one full entry by id" tool, if any. The `list`
        /// verb on a paginating source (MemPalace `list_drawers`) returns a
        /// TRUNCATED preview per item, not full content; a faithful transfer
        /// must fetch the full content of each item by id before writing it.
        /// MemPalace exposes `mempalace_get_drawer`. nil when `list` already
        /// returns full content (no separate fetch needed).
        let fetch: String?

        // MARK: Argument key names (per-verb argument construction)

        /// The argument key under which the write tool receives the entry
        /// content. Default `content` (MOOTx01 `moot_file_memory`, MemPalace
        /// `mempalace_add_drawer`).
        let contentArg: String
        /// The argument key under which the query tool receives the search
        /// text. Default `query` (both servers).
        let queryArg: String
        /// The argument key under which the `fetch` tool receives the item id.
        /// Default `drawer_id` (MemPalace `mempalace_get_drawer`).
        let fetchIDArg: String
        /// The key holding full content in a `fetch` result. MemPalace
        /// `get_drawer` returns a single object with full content under
        /// `content` (NOT the truncated `content_preview` the `list` returns).
        /// Default `content`.
        let fetchContentKey: String
        /// The argument key under which `list` receives the page size. Default
        /// `limit` (MemPalace `mempalace_list_drawers`).
        let listLimitArg: String
        /// The argument key under which `list` receives the page offset.
        /// Default `offset` (MemPalace `mempalace_list_drawers`).
        let listOffsetArg: String
        /// Page size for paginated enumeration. Default 100 (MemPalace's max).
        /// The transfer loops `offset` by this until a short/empty page.
        let listPageSize: Int
        /// Constant arguments every write call sends in addition to the
        /// content. Different servers require different fixed write context:
        /// MOOTx01's `moot_file_memory` requires one (`location`), MemPalace's
        /// `mempalace_add_drawer` requires two (`wing` + `room`). A map (not a
        /// single key) covers both without a per-server special case. Default:
        /// `{ "location": "import/mempalace" }` — the MOOTx01 import case.
        /// Set to `{}` for a write tool that needs only content.
        let constantArgs: [String: String]

        // MARK: Result shape

        /// How this server encodes the result of `query`/`list` (and how a
        /// write response carries its assigned id). Default: `jsonObjects`
        /// with `idKey: "id", contentKey: "content"` — the conventional shape
        /// the tool assumed before live shapes were known. Real configs name
        /// the actual shape (MemPalace `jsonObjects` with `drawer_id`/`text`;
        /// MOOTx01 `mootText`).
        let resultFormat: ResultFormat

        init(write: String,
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
             constantArgs: [String: String] = ["location": "import/mempalace"],
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
            self.resultFormat = resultFormat
        }

        private enum CodingKeys: String, CodingKey {
            case write, query, list, fetch
            case contentArg, queryArg, fetchIDArg, fetchContentKey
            case listLimitArg, listOffsetArg, listPageSize
            case constantArgs, resultFormat
        }

        // Custom decoder so an absent required verb surfaces as
        // ConfigError.missingField at load time, not as a generic
        // DecodingError.keyNotFound at first use. The argument-key and
        // result-format fields default when absent so a terse config still
        // decodes and runs live against the MOOTx01/MemPalace defaults.
        init(from decoder: Decoder) throws {
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
            // only content); an explicit map (e.g. wing+room) is sent verbatim.
            self.constantArgs = try c.decodeIfPresent([String: String].self, forKey: .constantArgs)
                ?? ["location": "import/mempalace"]
            self.resultFormat = try c.decodeIfPresent(ResultFormat.self, forKey: .resultFormat)
                ?? .jsonObjects(idKey: "id", contentKey: "content")
        }
    }

    enum EndpointRole: String, Codable, Sendable, Equatable { case source, target, both }
}

/// Top-level config: the source and target endpoints.
struct BenchmarkerConfig: Codable, Sendable, Equatable {
    let source: EndpointConfig
    let target: EndpointConfig

    /// Decodes config.json. Throws ConfigError.missingField when a required
    /// verbMap entry is absent — caught at load, not at first use.
    static func load(from url: URL) throws -> BenchmarkerConfig {
        let data = try Data(contentsOf: url)
        // A custom init(from:) on VerbMap may throw ConfigError; JSONDecoder
        // propagates such errors unchanged, so callers see ConfigError, not a
        // wrapped DecodingError.
        return try JSONDecoder().decode(BenchmarkerConfig.self, from: data)
    }
}
