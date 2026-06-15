import Foundation

// Config.swift — the bridge's JSON config schema and loader.
//
// Adapted (our code) from the proven benchmarker Config.swift. The bridge is
// engine-agnostic: it talks to two MCP servers whose tool names it does not know
// in advance. The `verbMap` on each backend is the decoupling layer — it names
// which of THIS server's MCP tools mean write vs. query, plus the argument keys
// and constant write-context each one needs, so the bridge is never hardcoded to
// MemPalace's or mootx01's specific tool names.
//
// Differences from the benchmarker config:
//   - Two NAMED backends (`backendA`, `backendB`) plus `primary` naming which one
//     starts as primary — instead of the benchmarker's source/target/role model.
//   - No list/fetch/pagination machinery: the bridge forwards reads verbatim to one
//     backend and only *translates* write/query calls for the secondary fan-out.
//     A transfer-style full enumeration is out of scope for a live memory server.
//
// Config is JSON, decoded via Foundation Codable. JSON (not YAML) is deliberate:
// zero external dependencies is a hard MOOTx01 standard, and Codable decodes JSON
// with no package; a YAML parser would need one.

/// Errors surfaced while loading or validating a bridge config.
/// `missingField` carries the dotted path of the absent required field (for
/// example `backendA.verbMap.write`) so failures are diagnosable at load time
/// rather than at first use.
enum ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingField(String)
    case unknownPrimary(String)

    var description: String {
        switch self {
        case .missingField(let path): return "config: missing required field \(path)"
        case .unknownPrimary(let name):
            return "config: primary=\"\(name)\" names no configured backend"
        }
    }
}

/// How a server encodes the result of a tool call. The bridge is engine-agnostic,
/// but the two real servers it targets return different shapes; the shape is
/// named in config rather than guessed. Carried from the benchmarker.
///
///   - `jsonObjects`: the result text block parses as a JSON object whose hits
///     live under `results`/`items`/`drawers` (or any single array-valued key).
///     `idKey` names each hit's id field (nil when the server returns no stable
///     id, e.g. MemPalace search), `contentKey` names its content field.
///     MemPalace search → `{ "results": [ { "text", ... } ] }`, so it maps with
///     `idKey: nil, contentKey: "text"`.
///   - `mootText`: mootx01's plain-text MCP results. A search returns
///     `found N memory(s)` then one ranked line per hit, each
///     `<UUID>  [location]  <content>`. A write returns `filed memory <UUID>`.
enum ResultFormat: Codable, Sendable, Equatable {
    case jsonObjects(idKey: String?, contentKey: String)
    case mootText

    private enum CodingKeys: String, CodingKey { case kind, idKey, contentKey }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "jsonObjects":
            self = .jsonObjects(
                idKey: try c.decodeIfPresent(String.self, forKey: .idKey),
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

/// Maps the bridge's two verbs (write, query) onto one backend's MCP tool names,
/// argument keys, and the constant write-context that backend requires.
///
/// `write` and `query` are required. The argument keys exist because tool NAMES
/// alone are not enough to drive a live call: mootx01's `moot_file_memory` needs
/// `{ content, location }`, MemPalace's `mempalace_add_drawer` needs
/// `{ wing, room, content }`, and both search tools take `{ query }`. The
/// defaults match the mootx01 argument names so a minimal config still runs;
/// override per-backend when a server names its arguments differently.
struct VerbMap: Codable, Sendable, Equatable {
    /// This server's "store an entry" tool (write-classified).
    let write: String
    /// This server's "search/recall" tool (query-classified).
    let query: String

    /// The argument key under which `write` receives the entry content.
    /// Default `content` (mootx01 `moot_file_memory`, MemPalace `add_drawer`).
    let contentArg: String
    /// The argument key under which `query` receives the search text.
    /// Default `query` (both servers).
    let queryArg: String
    /// Constant arguments every write call sends in addition to the content.
    /// Different servers require different fixed write context: mootx01's
    /// `moot_file_memory` requires one (`location`); MemPalace's
    /// `mempalace_add_drawer` requires two (`wing` + `room`). A map (not a single
    /// key) covers both without a per-server special case. Default:
    /// `{ "location": "bridge/mirror" }` — the mootx01 write case. Set to `{}` for
    /// a write tool that needs only content.
    let constantArgs: [String: String]
    /// How this server encodes the result of `query` (and how a write response
    /// carries its assigned id). Default: `mootText`.
    let resultFormat: ResultFormat

    init(write: String,
         query: String,
         contentArg: String = "content",
         queryArg: String = "query",
         constantArgs: [String: String] = ["location": "bridge/mirror"],
         resultFormat: ResultFormat = .mootText) {
        self.write = write
        self.query = query
        self.contentArg = contentArg
        self.queryArg = queryArg
        self.constantArgs = constantArgs
        self.resultFormat = resultFormat
    }

    private enum CodingKeys: String, CodingKey {
        case write, query, contentArg, queryArg, constantArgs, resultFormat
    }

    // Custom decoder so an absent required verb surfaces as
    // ConfigError.missingField at load time, not as a generic
    // DecodingError.keyNotFound at first use. The argument-key and result-format
    // fields default when absent so a terse config still decodes and runs.
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
        self.contentArg = try c.decodeIfPresent(String.self, forKey: .contentArg) ?? "content"
        self.queryArg = try c.decodeIfPresent(String.self, forKey: .queryArg) ?? "query"
        self.constantArgs = try c.decodeIfPresent([String: String].self, forKey: .constantArgs)
            ?? ["location": "bridge/mirror"]
        self.resultFormat = try c.decodeIfPresent(ResultFormat.self, forKey: .resultFormat)
            ?? .mootText
    }
}

/// One MCP backend the bridge fans out to. Engine-agnostic: the verbMap tells the
/// bridge which of THIS server's MCP tools mean write/query, so the bridge is not
/// hardcoded to MemPalace's or mootx01's tool names.
///
/// `command` is the full stdio launch command (an env-var prefix is honored,
/// e.g. `MOOTX01_DATA_DIR=/tmp/x mootx01 serve`). Treated at CLI-argument trust
/// level, the same boundary as the benchmarker's RawMCPBackend.
struct BackendConfig: Codable, Sendable, Equatable {
    let name: String
    let command: String
    let verbMap: VerbMap

    private enum CodingKeys: String, CodingKey { case name, command, verbMap }

    init(name: String, command: String, verbMap: VerbMap) {
        self.name = name
        self.command = command
        self.verbMap = verbMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try c.decodeIfPresent(String.self, forKey: .name) else {
            throw ConfigError.missingField("backend.name")
        }
        guard let command = try c.decodeIfPresent(String.self, forKey: .command) else {
            throw ConfigError.missingField("backend.command")
        }
        self.name = name
        self.command = command
        self.verbMap = try c.decode(VerbMap.self, forKey: .verbMap)
    }
}

/// Top-level bridge config: two named backends and which one starts as primary.
struct BridgeConfig: Codable, Sendable, Equatable {
    let backendA: BackendConfig
    let backendB: BackendConfig
    /// The `name` of the backend that starts as primary. Must equal
    /// `backendA.name` or `backendB.name`, else `ConfigError.unknownPrimary`.
    let primary: String

    private enum CodingKeys: String, CodingKey { case backendA, backendB, primary }

    init(backendA: BackendConfig, backendB: BackendConfig, primary: String) {
        self.backendA = backendA
        self.backendB = backendB
        self.primary = primary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backendA = try c.decode(BackendConfig.self, forKey: .backendA)
        self.backendB = try c.decode(BackendConfig.self, forKey: .backendB)
        guard let primary = try c.decodeIfPresent(String.self, forKey: .primary) else {
            throw ConfigError.missingField("primary")
        }
        // Validate at load time that `primary` names a real backend, so a typo
        // fails fast rather than silently defaulting at first read.
        guard primary == backendA.name || primary == backendB.name else {
            throw ConfigError.unknownPrimary(primary)
        }
        self.primary = primary
    }

    /// Decodes config.json. Throws ConfigError when a required verbMap entry is
    /// absent or `primary` names no backend — caught at load, not at first use.
    static func load(from url: URL) throws -> BridgeConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BridgeConfig.self, from: data)
    }
}
