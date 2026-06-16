---
title: Installer Interface
status: active
version: 1.0.3
date: 2026-06-15
description: Public API surface of the mootx01 installer CLI (Swift on macOS/iOS, Rust on Linux/Windows) plus the Swift-only MootInstallerCore host library.
spec_type: kit
authors: MOOTx01 maintainers
package: Installer
languages: [swift, rust]  # mootx01 CLI surface ships in both ports; the MootInstallerCore library is Swift-only
relates_to:
purpose: |
  Public API surface of the Installer. Type signatures, method
  shapes, error enums, and the `mootx01` CLI command surface. The
  companion SPEC document carries the behavioral contracts that
  these signatures must satisfy.
---

# Installer Interface

## § 1 — Package layout

**Swift:** `apps/mootx01/`

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

**Rust:** `apps/mootx01/rust/` — the Rust vertical that ships on Linux and
Windows. It reimplements the same `mootx01` CLI natively (no FFI), including
`install`/`uninstall` (`src/commands/install.rs`, `src/core/clients.rs`), and
wires the **same 12 MCP clients** with the same behavior as the Swift port
(detect each client, write its MCP config, grant tool permissions, back up
first). The Swift `MootInstallerCore` *library* has no Rust twin — its host
internals are reimplemented in the Rust `src/core/` module rather than shared.
There is no conformance-vector gate here: this is OS host glue (client-config
wiring), not deterministic substrate compute (the same carve-out as LoopbackHTTP).
`moot-mgr` (the observer/manager console) ships in both ports: the **macOS** build is a SwiftUI
app, and the **Rust** build (`apps/moot-mgr/rust`, headless, shipping on Linux and Windows) is a
complete vertical that serves the same loopback web dashboard, read-API, and control channel. The
control channel is a Unix-domain socket (chmod 0600) on Linux/macOS and a named pipe (owner-only
ACL) on Windows. Only the macOS SwiftUI GUI is not ported — the headless host serves the same
language-neutral web dashboard assets on every platform.

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
  swift test --package-path apps/mootx01
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

*End of Installer Interface.*

## Changelog

### 1.0.3 -- 2026-06-15
Corrected the moot-mgr platform claim again: the Rust `moot-mgr` now ships on **Windows as well as Linux**, not "headless Linux" only. Its admin control channel was reworked from a Unix-domain-socket-only transport to a cross-platform local socket (UDS chmod 0600 on Linux/macOS, named pipe with owner-only ACL on Windows) via the `interprocess` crate, satisfying the platform law (Rust targets Windows AND Linux). The Windows release archive now bundles `moot-mgr.exe`.

### 1.0.2 -- 2026-06-15
Corrected the moot-mgr platform claim: `moot-mgr` is not macOS-only. `apps/moot-mgr/rust` is a complete headless Linux vertical serving the same loopback web dashboard / read-API / control channel; only the macOS SwiftUI GUI is unported.

### 1.0.1 -- 2026-06-15
Corrected: the `mootx01` installer is **not** Swift-only. The Rust vertical (Linux/Windows) reimplements the same install/uninstall CLI natively and wires the same 12 MCP clients; `languages` is now `[swift, rust]`. Documented the split — CLI surface (both ports) vs `MootInstallerCore` library (Swift-only, reimplemented in Rust `core/`) vs `moot-mgr` (both ports; only its macOS SwiftUI GUI is unported — corrected in 1.0.2).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
