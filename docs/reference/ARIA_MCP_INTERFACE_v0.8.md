---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: ARIA_MCP
languages: [swift]   # access surface, implemented in Swift
relates_to:
  - ARIA_MCP_SPEC_v0.8.md  (the contract this interface implements)
  - ARIALEXICONLIB_SPEC_v0.8.md  (the grammar this surface projects)
  - GENIUSLOCUSKIT_SPEC_v0.8.md  (the estate verb surface tools dispatch to)
purpose: |
  Public API surface of ARIA_MCP — the stdio MCP server that projects
  the ARIA grammar onto Model Context Protocol tools and dispatches them
  against GeniusLocusKit estates. Documents the JSON-RPC transport, the
  JSONValue wire type, the lexicon→tool projection, the multi-estate
  tool dispatcher, and the server loop. The access surface is implemented in Swift. The
  companion SPEC carries the behavioral contracts.
---

# ARIA_MCP Interface

## § 1 — Package layout

**Swift:** `apps/ARIA_MCP/`

- `Sources/AriaMCP/` — the `AriaMCP` library: JSON-RPC envelope + error
  codes (`JSONRPC.swift`), the `JSONValue` wire type (`JSONValue.swift`),
  OSLog/stderr logging (`Logging.swift`), the server dispatcher + stdio
  loop (`Server.swift`), the lexicon→tool projection (`ToolProjection.swift`),
  the estate dispatcher (`ToolDispatch.swift`).
- `Sources/aria-mcp/` — the `aria-mcp` executable (`AriaMCPMain.swift`):
  opens an estate and runs the stdio loop.
- `Tests/AriaMCPTests/`
- `Package.swift` — depends on AriaLexiconLib, GeniusLocusKit, LocusKit,
  PersistenceKit (path deps under `../../packages/`).

**Rust:** none. ARIA_MCP is the external access surface above the substrate and is implemented in Swift.

This is the external access surface above the substrate; it is not
imported by any other package, so it is documented single-tier (its full
public API) rather than consumed-vs-broader tiers.

## § 2 — Public types

### Transport — JSON-RPC

```swift
public enum JSONRPCErrorCode {
    public static let parseError: Int          // -32700
    public static let invalidRequest: Int      // -32600
    public static let methodNotFound: Int      // -32601
    public static let invalidParams: Int       // -32602
    public static let internalError: Int       // -32603
    public static let toolDispatchFailure: Int // -32010 (server-defined)
}

public struct JSONRPCRequest: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?
    public init(jsonrpc: String, id: JSONValue?, method: String, params: JSONValue?)
    public var isNotification: Bool { get }           // id == nil
    public static func decode(_ value: JSONValue) -> JSONRPCRequest?
}

public struct JSONRPCResponse: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONValue
    public let payload: Payload
    public enum Payload: Sendable, Equatable { case result(JSONValue), error(JSONRPCError) }
    public init(id: JSONValue, payload: Payload)
    public static func ok(_ id: JSONValue, _ result: JSONValue) -> JSONRPCResponse
    public static func failure(_ id: JSONValue, _ error: JSONRPCError) -> JSONRPCResponse
    public var asJSONValue: JSONValue { get }
}

public struct JSONRPCError: Sendable, Equatable, Error {
    public let code: Int
    public let message: String
}
```

### Wire value — `JSONValue`

A hand-rolled JSON value (no Foundation `Codable` on the wire).

```swift
public enum JSONValue: Sendable, Equatable {
    // null / bool / integer / double / string / array / object cases
    public static func from(_ any: Any) throws -> JSONValue        // throws JSONValueError
    public static func parse(_ data: Data) throws -> JSONValue
    public func encoded() throws -> Data
    public var foundationObject: Any { get }
    public var objectValue: [String: JSONValue]? { get }
    public var stringValue: String? { get }
    public var integerValue: Int64? { get }
    public var boolValue: Bool? { get }
    public var arrayValue: [JSONValue]? { get }
}
public enum JSONValueError: Error, Equatable { /* unsupported value, etc. */ }
```

### Tool projection — `ToolProjection` / `ProjectedTool` / `ToolProvenance`

Generates the MCP tool list from the AriaLexicon acceptance matrix
(`verb_noun` actions, `noun_verb` for recall); `propose`/`associate` are
excluded as substrate-driven (SPEC). `cross_estate_recall` is the one
federation tool appended above the projection.

```swift
public enum ToolProvenance: Sendable, Equatable {
    case lexicon(verb: Verb, noun: Noun)   // Verb/Noun from AriaLexiconLib
    case federation
}
public struct ProjectedTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let provenance: ToolProvenance
    public var verb: Verb? { get }
    public var noun: Noun? { get }
}
public enum ToolProjection {
    public static func surfaces(_ verb: Verb) -> Bool                 // false for substrate-driven
    public static func tools() -> [ProjectedTool]                     // full projected list + federation tool
    public static func make(verb: Verb, noun: Noun) -> ProjectedTool
    public static func federationTool() -> ProjectedTool
    public static func toolName(verb: Verb, noun: Noun) -> String
}
```

### Dispatch — `ToolDispatcher` / `ClassificationScheme`

Routes a `tools/call` against one or more locally-open GeniusLocusKit
estates (by optional `estateID`; absent ⇒ default).

```swift
public struct ToolDispatcher: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public init(kit: GeniusLocusKit, handle: EstateHandle)
    public func registering(_ additional: EstateHandle) -> ToolDispatcher   // value-semantic add
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue
    public static func parseToolName(_ name: String) -> (Verb, Noun)?
    public func parseToolName(_ name: String) -> (Verb, Noun)?
    public static let crossEstateRecallToolName: String   // "cross_estate_recall"
    public static func textResult(_ text: String) -> JSONValue   // MCP success, isError:false
    public static func errorResult(_ text: String) -> JSONValue  // MCP result, isError:true
}

// Declared at the ARIA boundary (substrate LatticeAnchor carries no scheme tag yet).
public enum ClassificationScheme: String, Sendable, CaseIterable { case udc, mdcc }
```

### Server — `ARIA_MCPDispatcher` / `StdioServer`

The method router and the newline-delimited stdio loop.

```swift
public struct ARIA_MCPDispatcher: Sendable {
    public struct ServerInfo: Sendable { public let name: String; public let version: String
                                         public init(name: String, version: String) }
    public let info: ServerInfo
    public let tools: [ProjectedTool]
    public let tooling: ToolDispatcher
    public init(info: ServerInfo, tooling: ToolDispatcher)
    // Handles initialize / ping / tools/list / tools/call; nil for notifications.
    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse?
}

public struct StdioServer: Sendable {
    public let dispatcher: ARIA_MCPDispatcher
    public init(dispatcher: ARIA_MCPDispatcher)
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async
    public func handleFrame(_ frame: Data, output: FileHandle) async
    public func write(_ response: JSONRPCResponse, to output: FileHandle)
}
```

### Logging

```swift
public enum Logging {
    public static let osLog: Logger          // subsystem "com.mootx01.kit", category "AriaMCP"
    public static let stderr: StderrLogger
}
public struct StderrLogger: Sendable { public init(); public func log(_ message: String) }
```

## § 3 — Public functions

MCP methods are routed by `ARIA_MCPDispatcher.handle(_:)`:
`initialize` (echoes `protocolVersion`, advertises the `tools`
capability), `ping`, `tools/list` (from `ToolProjection.tools()`),
`tools/call` (→ `ToolDispatcher.dispatch(name:arguments:)`). The
`aria-mcp` executable wires a `GeniusLocusKit` estate into a
`ToolDispatcher`, builds an `ARIA_MCPDispatcher`, and runs
`StdioServer.run()`. Behavioral contracts: SPEC.

## § 4 — Errors

```swift
public struct JSONRPCError: Sendable, Equatable, Error { public let code: Int; public let message: String }
public enum JSONValueError: Error, Equatable
```
Out-of-band conditions (unknown tool, malformed arguments, unknown
`estateID`) surface as JSON-RPC errors; substrate refusals
(`VerbError`, `GeniusLocusKitError`) come back as `tools/call` results
with `isError: true` so the client keeps the call id. See SPEC § 6.

## § 5 — Conformance test entry points

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path apps/ARIA_MCP
```

(Targets: `AriaMCPTests` — JSON-RPC, stdio framing, server, tool
projection, multi-estate routing, scheme discriminator.) No Rust version.

## § 6 — Examples

```swift
import AriaMCP
import GeniusLocusKit

let dispatcher = ARIA_MCPDispatcher(
    info: .init(name: "aria-mcp", version: "0.8"),
    tooling: ToolDispatcher(kit: kit, handle: estate)
)
await StdioServer(dispatcher: dispatcher).run()   // newline-delimited JSON-RPC over stdio
```

---

*End of ARIA_MCP Interface v0.8.*
