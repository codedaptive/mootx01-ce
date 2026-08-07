---
title: Installer Interface
status: active
version: 1.2.0
date: 2026-08-07
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
  - `HarnessMemory.swift` — Harness Memory Mode (MXE-HM): `HarnessMemoryPaths`,
    `HarnessMemorySettings`, `HarnessMemoryCLAUDE`, `HarnessMemoryHook`,
    `HarnessMemoryRecord`, `DaemonClient` (protocol), `LiveDaemonClient`,
    `DaemonError`, `HarnessMemoryMatcher`, `IngestResult`, `HarnessMemoryIngest`,
    `RestoreResult`, `HarnessMemoryRestore`
- `Sources/mootx01/` — the `mootx01` executable
  - `MootMain.swift` — `@main Mootx01` root `AsyncParsableCommand`
  - `Commands/` — `ServeCommand`, `InstallCommand`, `UninstallCommand`,
    `DbCommand` (+ `DbCreate`/`DbList`/`DbOpen`/`DbDelete`),
    `StatusCommand`, `QueryCommand`, `EnableCommand`, `DisableCommand`,
    `HookCaptureCommand`
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
    public static let serverName: String           // "mootx01" — DIRECT entries
    public static let pluginServerName: String     // "memory"  — PLUGIN packages
    public static let supported: [MCPClient]       // claude-desktop, claude-code,
                                                   // cursor, cline, continue
}
```

The two server-name keys are deliberately distinct and are not
interchangeable.

`serverName` is the key for a **direct** (non-plugin) MCP entry — the
one the installer merges into a client's own config file.

`pluginServerName` is the key inside a generated **plugin package**'s
MCP manifest. The host namespaces a plugin's servers under the plugin
id, so a plugin entry surfaces to the user as `plugin:mootx01:memory`.
A direct entry carries no such namespace, which is why it keeps
`mootx01` — and why the plugin-ownership hook can still distinguish a
competing direct entry from the plugin's own.

Code that reads a **generated plugin package** must use
`pluginServerName`; code that reads or writes a **client's own config**
must use `serverName`. The generated packages are the authority for
`pluginServerName`'s value; the constant mirrors them, and
`PluginPackageShapeTests` fails if the mirror drifts.

The Rust port carries the same pair in `core::clients`:

```rust
pub const SERVER_NAME: &str = "mootx01";         // DIRECT entries
pub const PLUGIN_SERVER_NAME: &str = "memory";   // PLUGIN packages
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

### Harness Memory Mode types (MXE-HM)

The following types ship in `MootInstallerCore/HarnessMemory.swift` and are
used by the `enable harness-memory` / `disable harness-memory` CLI commands
and the `hook-capture` hook handler.

```swift
/// Path constants for Harness Memory Mode files under ~/.mootx01/.
public enum HarnessMemoryPaths {
    public static func hooksDirURL(homeDirectory: URL) -> URL
    public static func hookScriptURL(homeDirectory: URL) -> URL
    public static func globalCLAUDEMDURL(homeDirectory: URL) -> URL
    public static func claudeProjectsURL(homeDirectory: URL) -> URL
}

/// Pure JSON transforms for Claude settings.json harness-memory toggles.
public enum HarnessMemorySettings {
    public static let autoMemoryKey: String  // "autoMemoryEnabled"
    public static func enable(settingsURL: URL, homeDirectory: URL) throws
    public static func disable(settingsURL: URL, homeDirectory: URL) throws
    public static func hasHookEntry(in settings: [String: Any], commandPath: String) -> Bool
    public static func addHookEntry(to settings: inout [String: Any], commandPath: String)
    public static func removeHookEntry(from settings: inout [String: Any], commandPath: String)
    public static func backupIfPresent(settingsURL: URL) throws
    public static func readSettings(at url: URL) throws -> [String: Any]
    public static func writeSettings(_ settings: [String: Any], to url: URL) throws
}

/// CLAUDE.md block management: merges / removes the sentinel-marked teaching block.
public enum HarnessMemoryCLAUDE {
    public static let beginMarker: String  // "<!-- mootx01:harness-memory:begin -->"
    public static let endMarker: String   // "<!-- mootx01:harness-memory:end -->"
    public static func hasBlock(in text: String) -> Bool
    public static func mergeBlock(into text: String) -> String   // idempotent
    public static func removeBlock(from text: String) -> String  // idempotent
    public static func enable(at url: URL) throws
    public static func disable(at url: URL) throws
}

/// Thin shell hook script lifecycle (install / remove).
public enum HarnessMemoryHook {
    public static func scriptContent(binaryPath: String) -> String
    public static func install(at url: URL, binaryPath: String) throws
    public static func remove(at url: URL) throws
}

/// Describes a memory record in the estate relevant to ingest / restore.
public struct HarnessMemoryRecord: Sendable {
    public let id: String
    public let location: String
    public let content: String
    public let eventTime: Date
    public let isSuperseded: Bool
}

/// Protocol for daemon communication (JSON-RPC 2.0 over loopback HTTP).
/// Abstracted for testability — `MockDaemonClient` in tests; `LiveDaemonClient` in production.
public protocol DaemonClient: Sendable {
    func fileMemory(location: String, content: String, eventTime: Date, kind: String?) async throws -> Bool
    func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord]
    func updateMemory(id: String, mutation: String, note: String?) async throws
    func ping() async -> Bool
}

/// Production daemon client: JSON-RPC 2.0 POST to http://127.0.0.1:<port>.
public struct LiveDaemonClient: DaemonClient {
    public init(port: Int)
}

/// Path matching for Claude Code project memory files.
/// Matches paths of the shape `<any>/.claude/projects/<slug>/memory/<name>`.
public enum HarnessMemoryMatcher {
    public static func match(path: String) -> (projectSlug: String, fileName: String)?
    public static var teachingMessage: String { get }
}

/// Result of ingesting one Claude Code project memory file into the estate.
public struct IngestResult: Sendable {
    public enum Outcome: Sendable {
        case filed
        case revived
        case skipped(String)
        case failed(String)
    }
    public let location: String
    public let outcome: Outcome
}

/// Ingest scanner: MOVE semantics — reads on-disk memory files, files them in
/// the estate, then deletes the source (or revives a superseded drawer on re-enable).
public enum HarnessMemoryIngest {
    public static func scanProjects(homeDirectory: URL) throws -> [(slug: String, files: [URL])]
    public static func ingestFile(
        _ url: URL,
        projectSlug: String,
        isReEnable: Bool,
        daemon: some DaemonClient,
        now: Date
    ) async -> IngestResult
    public static func removeEmptyMemoryDir(projectSlug: String, homeDirectory: URL) throws
}

/// Result of restoring one memory from the estate back to disk.
public struct RestoreResult: Sendable {
    public enum Outcome: Sendable {
        case restored
        case skipped(String)
        case failed(String)
    }
    public let location: String
    public let outcome: Outcome
}

/// Restore: writes estate memories back to ~/.claude/projects/<slug>/memory/<name>
/// and marks them superseded in the estate (reverse of ingest).
public enum HarnessMemoryRestore {
    public static func restore(
        projectSlugs: [String],
        homeDirectory: URL,
        daemon: some DaemonClient,
        now: Date
    ) async throws -> [RestoreResult]
}
```

## § 3 — Public functions

The library exposes no free functions; all operations are static
members of the caseless-enum namespaces in § 2.

### CLI command surface (`mootx01` executable)

The root command is `@main struct Mootx01: AsyncParsableCommand`
(command name `mootx01`). Subcommands:

| Subcommand | Command name | Platforms | Shown in --help |
|---|---|---|---|
| `ServeCommand` | `serve` | macOS only (default subcommand) | yes |
| `InstallCommand` | `install` | all | yes |
| `UninstallCommand` | `uninstall` | all | yes |
| `DbCommand` | `db` (subcommands: `create`, `list`, `open`, `delete`) | all | yes |
| `StatusCommand` | `status` | all | yes |
| `QueryCommand` | `query` | all | yes |
| `EnableCommand` | `enable` (subcommand: `harness-memory`) | all | yes |
| `DisableCommand` | `disable` (subcommand: `harness-memory`) | all | yes |
| `HookCaptureCommand` | `hook-capture` | all | no (internal) |

On non-macOS platforms `serve` is omitted (it requires the Apple-only
MCP server runtime); on macOS `serve` is the default subcommand so a
bare `mootx01` invocation in an MCP client config starts the server.

`HookCaptureCommand` (`hook-capture`) is the PreToolUse hook handler
invoked by `~/.mootx01/hooks/capture-harness-memory.sh`. It is
registered in the subcommand list but hidden from `--help`
(`shouldDisplay: false`). It reads a Claude Code PreToolUse JSON event
from stdin and emits a JSON `permissionDecision` response to stdout.

`EnableCommand` (`enable harness-memory`) and `DisableCommand`
(`disable harness-memory`) accept the following flags:

```
enable harness-memory [-y/--yes] [--ingest-all]
  -y / --yes        Suppress all confirmation prompts.
  --ingest-all      Ingest all existing project memory files without per-file prompts.

disable harness-memory [-y/--yes] [--restore-all | --no-restore]
  -y / --yes        Suppress all confirmation prompts.
  --restore-all     Restore all estate memories to disk without per-project prompts.
  --no-restore      Skip the restore offer entirely.
```

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

/// Errors thrown by `LiveDaemonClient` (JSON-RPC 2.0 over loopback HTTP).
public enum DaemonError: Error, CustomStringConvertible {
    case httpError(Int)     // non-2xx HTTP response code
    case parseError         // response body not valid JSON-RPC 2.0
    case rpcError(String)   // JSON-RPC error.message from the daemon
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

### 1.2.0 -- 2026-08-07
Added Harness Memory Mode (MXE-HM) public surface. New `MootInstallerCore` types:
`HarnessMemoryPaths`, `HarnessMemorySettings`, `HarnessMemoryCLAUDE`, `HarnessMemoryHook`,
`HarnessMemoryRecord` (Sendable struct), `DaemonClient` (Sendable protocol),
`LiveDaemonClient`, `DaemonError` (new error type), `HarnessMemoryMatcher`,
`IngestResult` + `HarnessMemoryIngest`, `RestoreResult` + `HarnessMemoryRestore`.
New CLI subcommands: `enable harness-memory` (`EnableCommand`) and
`disable harness-memory` (`DisableCommand`), each with `-y`/`--yes` and
`--ingest-all` / `--restore-all` / `--no-restore` flags.
New internal subcommand: `hook-capture` (`HookCaptureCommand`, `shouldDisplay: false`),
invoked by `~/.mootx01/hooks/capture-harness-memory.sh` as a Claude Code PreToolUse
hook handler. Minor-version bump: additive surface, no existing signature changed.

### 1.1.0 -- 2026-08-03
Added `MCPClients.pluginServerName` (Swift) and `core::clients::PLUGIN_SERVER_NAME` (Rust) to the documented surface, and scoped `serverName` / `SERVER_NAME` to DIRECT (non-plugin) entries. The plugin package's MCP server key became `memory` at `7f64973aa` so plugin tools surface as `plugin:mootx01:memory`; direct entries deliberately keep `mootx01`. Both keys are now named constants rather than scattered literals, and the two are not interchangeable. Minor bump: additive surface, no existing signature changed.

### 1.0.3 -- 2026-06-15
Corrected the moot-mgr platform claim again: the Rust `moot-mgr` now ships on **Windows as well as Linux**, not "headless Linux" only. Its admin control channel was reworked from a Unix-domain-socket-only transport to a cross-platform local socket (UDS chmod 0600 on Linux/macOS, named pipe with owner-only ACL on Windows) via the `interprocess` crate, satisfying the platform law (Rust targets Windows AND Linux). The Windows release archive now bundles `moot-mgr.exe`.

### 1.0.2 -- 2026-06-15
Corrected the moot-mgr platform claim: `moot-mgr` is not macOS-only. `apps/moot-mgr/rust` is a complete headless Linux vertical serving the same loopback web dashboard / read-API / control channel; only the macOS SwiftUI GUI is unported.

### 1.0.1 -- 2026-06-15
Corrected: the `mootx01` installer is **not** Swift-only. The Rust vertical (Linux/Windows) reimplements the same install/uninstall CLI natively and wires the same 12 MCP clients; `languages` is now `[swift, rust]`. Documented the split — CLI surface (both ports) vs `MootInstallerCore` library (Swift-only, reimplemented in Rust `core/`) vs `moot-mgr` (both ports; only its macOS SwiftUI GUI is unported — corrected in 1.0.2).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
