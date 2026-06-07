---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-26
version: v0.1
package: Installer
languages: [swift]  # Swift-only; no Rust port (CLI/installer app, not a kit)
relates_to:
  - INSTALLER_SPEC_v0.1.md  (the contract this interface implements)
purpose: |
  Public API surface of the Installer. Type signatures, method
  shapes, error enums, and the `mootx01` CLI command surface. The
  companion SPEC document carries the behavioral contracts that
  these signatures must satisfy.
---

# Installer Interface

## § 1 — Package layout

**Swift:** `installer/`

- `Sources/MootInstallerCore/` — the `MootInstallerCore` library:
  install/uninstall logic, client detection, path resolution, estate
  database management, permissions writing
  - `Installer.swift` — `Installer` (install / writeMOOTmd / uninstall)
  - `Paths.swift` — `MootPaths`
  - `ClientConfig.swift` — `MCPClient`, `MCPClients`, `MCPServerEntry`,
    `MCPServerEntryBuilder`
  - `AgentPicker.swift` — `AgentPicker`, `AgentPickerError`
  - `DatabaseManager.swift` — `DatabaseManager`, `MOOTx01DatabaseError`
  - `PermissionsWriter.swift` — `PermissionsWriter`
- `Sources/mootx01/` — the `mootx01` executable
  - `MootMain.swift` — `@main Mootx01` root `AsyncParsableCommand`
  - `Commands/` — `ServeCommand`, `InstallCommand`, `UninstallCommand`,
    `DbCommand` (+ `DbCreate`/`DbList`/`DbOpen`/`DbDelete`),
    `StatusCommand`, `QueryCommand`
- `Tests/MootInstallerCoreTests/` — conformance tests
- `Package.swift` — manifest

Two products: `.library(name: "MootInstallerCore")` and
`.executable(name: "mootx01")`. The executable depends on
swift-argument-parser (CLI app exception — not a kit) plus the
in-repo products AriaMCP, AriaLexiconLib, GeniusLocusKit, LocusKit,
PersistenceKit, PersistenceKitSQLite.

**Rust:** none. The installer is a Swift-only CLI/host app; it is not
a substrate kit and has no Rust parity port.

## § 2 — Public types

### `Installer`

Caseless-enum namespace for the install/uninstall operations against an
MCP client's JSON (or Continue YAML) config.

```swift
public enum Installer {
    public static func install(
        client: MCPClient,
        binaryPath: String,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws

    public static func writeMOOTmd(
        homeDirectory: URL,
        local: Bool,
        workingDirectory: URL
    ) throws

    public static func uninstall(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws
}
```

### `MootPaths`

Path/constant resolution for the data directory, estate database, and
Claude/MCP config locations.

```swift
public enum MootPaths {
    public static let dataDirEnvVar: String            // "MOOTX01_DATA_DIR"
    public static let estateFileName: String           // "estate.sqlite"
    public static let defaultOwnerIdentifier: String   // "mootx01-user"

    public static func resolveDataDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL
    public static func estateURL(in dataDirectory: URL) -> URL
    public static func localMCPConfigURL(workingDirectory: URL) -> URL
    public static func globalClaudeSettingsURL(homeDirectory: URL) -> URL
    public static func localClaudeSettingsURL(workingDirectory: URL) -> URL
}
```

### `MCPClient`, `MCPClients`

A supported MCP client and the registry of supported clients.

```swift
public struct MCPClient: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let configPath: String
    public let serverName: String
    public let detectPath: String?
    public let localConfigPath: String?
    public init(id: String, displayName: String, configPath: String,
                serverName: String, detectPath: String? = nil,
                localConfigPath: String? = nil)
    public func isPresent(homeDirectory: URL) -> Bool
}

public enum MCPClients {
    public static let serverName: String          // "mootx01"
    public static let supported: [MCPClient]       // claude-desktop, claude-code,
                                                   // cursor, cline, continue
}
```

### `MCPServerEntry`, `MCPServerEntryBuilder`

The server-entry value written into each client's config, and its
builder.

```swift
public struct MCPServerEntry: Sendable, Equatable, Codable {
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public init(command: String, args: [String] = [], env: [String: String] = [:])
}

public enum MCPServerEntryBuilder {
    public static func entry(binaryPath: String) -> MCPServerEntry
    public static func entryJSON(binaryPath: String) throws -> String
}
```

### `AgentPicker`

Selects which detected MCP clients to wire, with an interactive prompt
fallback.

```swift
public enum AgentPicker {
    public static func pick(
        yes: Bool,
        target: String?,
        homeDirectory: URL
    ) throws -> [MCPClient]
}
```

### `DatabaseManager`

Estate-database lifecycle on disk (create / list / open / delete /
purge) and active-estate selection.

```swift
public enum DatabaseManager {
    public static func estateURL(for name: String, in dataDirectory: URL) -> URL
    public static func activeEstateName(in dataDirectory: URL) throws -> String
    public static func setActiveEstate(_ name: String, in dataDirectory: URL) throws
    public static func createEstate(name: String, in dataDirectory: URL) throws
    public static func listEstates(in dataDirectory: URL) -> [String]
    public static func deleteEstate(name: String, in dataDirectory: URL) throws
    public static func purgeDefaultEstate(in dataDirectory: URL) throws
}
```

### `PermissionsWriter`

Merges the ARIA tool permission allowlist into a Claude settings file.

```swift
public enum PermissionsWriter {
    public static let ariaToolNames: [String]      // 22 moot_* tool names
    public static let permissionEntries: [String]  // ariaToolNames mapped to permission strings
    public static func merge(into settingsURL: URL) throws
    public static func remove(from settingsURL: URL) throws
}
```

## § 3 — Public functions

The library exposes no free functions; all operations are static
members of the caseless-enum namespaces in § 2.

### CLI command surface (`mootx01` executable)

The root command is `@main struct Mootx01: AsyncParsableCommand`
(command name `mootx01`). Subcommands:

| Subcommand | Command name | Platforms |
|---|---|---|
| `ServeCommand` | `serve` | macOS only (default subcommand) |
| `InstallCommand` | `install` | all |
| `UninstallCommand` | `uninstall` | all |
| `DbCommand` | `db` (subcommands: `create`, `list`, `open`, `delete`) | all |
| `StatusCommand` | `status` | all |
| `QueryCommand` | `query` | all |

On non-macOS platforms `serve` is omitted (it requires the Apple-only
MCP server runtime); on macOS `serve` is the default subcommand so a
bare `mootx01` invocation in an MCP client config starts the server.

## § 4 — Errors

```swift
public enum AgentPickerError: Error, CustomStringConvertible {
    case unknownClient(String)
}

public enum MOOTx01DatabaseError: Error, CustomStringConvertible {
    case alreadyExists(String)
    case notFound(String)
    case invalidName(String)
    case deleteDefault
}
```

Install/uninstall and path operations throw the underlying
Foundation/PersistenceKit errors directly (FileManager, JSON
decoding, SQLite open) rather than a dedicated `InstallerError` enum.

## § 5 — Conformance test entry points

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path installer
```

(Target: `MootInstallerCoreTests`.)

## § 6 — Examples

```swift
import MootInstallerCore
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// Pick the MCP clients to wire (non-interactive: all detected).
let clients = try AgentPicker.pick(yes: true, target: nil, homeDirectory: home)

// Wire mootx01 into each client's config (global install).
for client in clients {
    try Installer.install(
        client: client,
        binaryPath: "/usr/local/bin/mootx01",
        homeDirectory: home,
        workingDirectory: cwd,
        local: false
    )
}

// Resolve the data dir and the active estate database.
let dataDir = MootPaths.resolveDataDirectory(
    environment: ProcessInfo.processInfo.environment,
    homeDirectory: home
)
let estate = DatabaseManager.estateURL(for: "default", in: dataDir)
```

---

*End of Installer Interface v0.1.*
