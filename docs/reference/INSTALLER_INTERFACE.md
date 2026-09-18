---
title: Installer Interface
status: active
version: 2.0.0
date: 2026-09-15
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

Install-side path constants: installed binaries and symlinks, client config
locations, launchd labels and plists, the logs directory, the resident
daemon's port file and the moot-mgr stats store. Estates are not located
here: the estate catalog (GeniusLocusKit `EstateCatalog`, spec
§ ESTATE_CATALOG) names every estate directory, and
`EstateCatalog.configurationDirectory` is the `dataDir` the two helpers
below take.

```swift
public enum MootPaths {
    public static let defaultOwnerIdentifier: String   // "mootx01-user"
    public static func localMCPConfigURL(workingDirectory: URL) -> URL
    public static func globalClaudeSettingsURL(homeDirectory: URL) -> URL
    public static func localClaudeSettingsURL(workingDirectory: URL) -> URL
    public static func installedBinaryDirURL(homeDirectory: URL) -> URL
    public static func installedBinaryURL(homeDirectory: URL) -> URL
    public static func localBinDirURL(homeDirectory: URL) -> URL
    public static func binarySymlinkURL(homeDirectory: URL) -> URL
    public static func proxySymlinkURL(homeDirectory: URL) -> URL
    public static func botLinkSymlinkURL(homeDirectory: URL) -> URL
    public static func installedMgrBinaryURL(homeDirectory: URL) -> URL
    public static func mgrSymlinkURL(homeDirectory: URL) -> URL
    public static func logsDirURL(homeDirectory: URL) -> URL
    public static let launchAgentLabel: String           // "com.mootx01.mgr"
    public static func launchAgentPlistURL(homeDirectory: URL) -> URL
    public static let daemonLabel: String                // "com.mootx01.daemon"
    public static func daemonPlistURL(homeDirectory: URL) -> URL
    public static func daemonStatsStoreDefault(dataDir: URL) -> String
    public static func daemonStatsStorePath(dataDir: URL) -> String
    public static let defaultResidentPort: Int           // 4242
    public static var residentEndpointURL: String
    public static func daemonPortFileURL(in dataDir: URL) -> URL
    public static func resolvedResidentPort(dataDir: URL) -> Int
}
```

### `MootProductIdentity.Settings` (R6 — 2026-09-09)

A product-wide settings reader that loads `<config-dir>/config.json` and
returns typed values with defaults. Both `AriaResident.statsStorePath` /
Rust `stats_store_path` and both `ManagerConfig` defaults read through this
reader so the daemon and moot-mgr always agree on the stats-store path.

`mootx01 install` calls `seedDefaultsIfAbsent` to write the default into
`config.json` when the key is absent. The call is idempotent: a second run
with the key already set leaves the file untouched. `mootx01 upgrade` does
not touch `config.json`.

JSON shape: `{"daemon": {"stats_store": "<absolute-path>"}}`. Unknown keys
are silently ignored. An empty string for `stats_store` is treated as absent.

```swift
// MootProductIdentity.Settings (Swift)
public struct Settings: Sendable {
    public let daemonStatsStore: String?    // nil means absent → caller uses default
    public static func load(configurationDirectory: URL = ...) -> Settings
    @discardableResult
    public static func seedDefaultsIfAbsent(
        defaultStatsStorePath: String,
        configurationDirectory: URL = ...
    ) -> Bool
}
```

```rust
// moot_product_identity::settings (Rust)
pub struct ProductSettings { pub daemon_stats_store: Option<String> }
pub fn load(config_dir: &Path) -> ProductSettings
pub fn seed_defaults_if_absent(config_dir: &Path, default_stats_store_path: &str)
    -> io::Result<bool>   // Ok(true) = key already present; Ok(false) = file written
```

**Seeder return-value divergence (intentional).** The Swift and Rust signatures differ:
- Swift returns `Bool`: `true` means the key was already present **or** the file was written
  successfully; `false` means the write failed. Callers check `false` to detect failure.
- Rust returns `io::Result<bool>`: `Ok(true)` = key already present (no write),
  `Ok(false)` = file written; `Err(e)` = I/O failure. Callers match `Err` to detect failure.

Both ports surface a non-fatal warning to stderr when the seed fails (`mootx01: warning: could
not seed config.json`). No migration or user-visible divergence follows from the difference —
the distinction between "already present" and "just wrote" is not observable by the caller.

`MootPaths.daemonStatsStoreDefault(dataDir:)` returns the pure computed
default path (`<config-dir>/moot-mgr/stats.sqlite`) with no settings lookup —
used by the install seeder to get the value to write without a circular read.
`MootPaths.daemonStatsStorePath(dataDir:)` checks `Settings.load` first and
falls back to `daemonStatsStoreDefault`.

### `EstateOpen`

The single entry point for opening the estate catalog in both ports.
Runs two steps in order: (a) Windows base-directory adoption (no-op on
Apple platforms — the step is present so both ports have an identical
funnel shape); (b) `EstateCatalog.open` or `EstateCatalog.open(selecting:)`
when a name or path is given.

```swift
public enum EstateOpen {
    public static let steps: [String]  // ["windows_base_adoption", "catalog_open"]
    public static func catalog(selecting db: String?) throws -> EstateCatalog
}
```

Rust twin: `core::estate_open::catalog(selecting: Option<&str>)` in
`apps/mootx01/rust/src/core/estate_open.rs`. Both ports declare `STEPS`
and read by the cross-port parity test via `estate_open_steps.json`.

### `ResidentDaemonQuiesce`

The one place `mootx01 upgrade` stops and restarts the resident daemon
around an estate migration step. The decision is the estate's own PID
marker (`EstateRecord.pidURL`): when it names a live, identity-verified
mootx01 process other than the caller, a resident serves this estate and the
step runs with the daemon stopped and restarted afterwards on every outcome;
otherwise the daemon is left running and the step prints
`no live resident serves this estate; daemon left running`. Returns `nil`
when the daemon was running and would not stop, in which case the step is
skipped and the next upgrade retries. The flat-layout step passes
`residentServes: true` directly, because a pre-catalog estate has no marker
(GeniusLocusKit interface 3.7.0).

```swift
public enum ResidentDaemonQuiesce {
    public static func run<T>(
        estatePIDURL: URL,
        step: String,
        daemon: EstateEncryptionMigrator.DaemonControl,
        work: () async -> T
    ) async -> T?
    public static func run<T>(
        residentServes: Bool,
        step: String,
        daemon: EstateEncryptionMigrator.DaemonControl,
        work: () async -> T
    ) async -> T?
    public static func residentServes(pidURL: URL) -> Bool
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
                                                   // cursor, cline, continue,
                                                   // codex, opencode, hermes,
                                                   // gemini-cli, antigravity,
                                                   // kiro, grok
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
    func fileMemory(location: String, content: String, subject: String, eventTime: Date, kind: String?) async throws -> Bool
    /// Active records only, complete across every server page (the server never lists a superseded row).
    func listMemories(locationPrefix: String) async throws -> [HarnessMemoryRecord]
    /// nil when the server refuses with `memory_not_found` (unknown or superseded id); throws otherwise.
    func getMemory(id: String) async throws -> HarnessMemoryRecord?
    func ping() async -> Bool
}

/// Production daemon client: JSON-RPC 2.0 POST to http://127.0.0.1:<port>.
/// `listMemories` sends `{wing: "Agentic Memory", limit: 200}` (plus `room` for an
/// exact file location), follows `has_more` / `next_cursor` across pages, restarts
/// without a cursor on a `cursor_stale` or `cursor_expired` refusal (at most three
/// times), then fetches records with `moot_memory_get {memory_ids}` in chunks of 50.
/// A batch answering fewer records than asked throws `DaemonError.refused("memory_not_found")`.
public struct LiveDaemonClient: DaemonClient {
    public init(port: Int)
}

/// Byte-exact carrier for one `<key>: <value>` line under `metadata:` in a file's
/// front matter. Line-based, `\n` only, no regex, no YAML parser; `strip` is the
/// inverse of `inject` for the same key. Three cases: an existing block with a
/// `metadata:` line gains `  <key>: <value>` directly after it; a block without
/// `metadata:` gains `metadata:` plus the key line before the closing fence; a
/// file without a block gains a four-line block holding only `metadata:` and the
/// key line. Two keys ride on it: `moot_memory_id` (the estate row of a restored
/// file) and `moot_generated_index` (value `true`, marks the MEMORY.md restore
/// generates). The memory-id overloads are thin wrappers over the keyed forms.
public enum HarnessMemoryFrontMatter {
    public static let key: String                 // "moot_memory_id"
    public static let generatedIndexKey: String   // "moot_generated_index"
    public static func inject(_ content: String, key: String, value: String) -> String
    public static func strip(_ content: String, key: String) -> (value: String?, body: String)
    public static func inject(_ content: String, memoryId: String) -> String
    public static func strip(_ content: String) -> (memoryId: String?, body: String)
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
        case filed              // posted to the estate, source removed
        case matched            // the file's moot_memory_id row already holds this content: source removed, row untouched
        case discardedIndex     // a restore-generated MEMORY.md (moot_generated_index: true, no id): source removed, no estate call
        case skipped(String)
        case failed(String)
    }
    public let filePath: String
    public let projectSlug: String
    public let fileName: String
    public let outcome: Outcome
}

/// Ingest scanner: MOVE semantics — reads on-disk memory files, files them in
/// the estate, then deletes the source. A file restored by `HarnessMemoryRestore`
/// carries its estate id in `moot_memory_id` front matter; the front matter is
/// stripped and the id is matched by `getMemory` to a row at `<prefix>/<slug>/<name>`
/// (`harness-import` or `harness`) with the same slug and name. Equal content →
/// `.matched`, row untouched. Changed content → `.filed`: the old row is left
/// untouched (never superseded, never revived) and the new body is filed fresh
/// at the row's own location, so the estate gains a second row for that
/// (slug, filename) pair. No id, an unknown id, or a row elsewhere → filed fresh at
/// `harness-import/<slug>/<name>`. A
/// `MEMORY.md` (case-insensitive) with no id and `moot_generated_index: true` is the
/// index restore generated: removed, `.discardedIndex`, no estate call. An authored
/// `MEMORY.md` without either key is filed with kind `list`.
public enum HarnessMemoryIngest {
    public static func scanProjects(homeDirectory: URL) -> [String: [URL]]
    public static func ingestFile(
        _ url: URL,
        projectSlug: String,
        daemon: some DaemonClient,
        now: Date = Date()
    ) async -> IngestResult
    public static func extractSubject(from content: String, fileName: String) -> String
    /// "filed N, matched N, discarded indexes N, removed N, skipped N": the Rust per-project line.
    /// filed = .filed; matched = .matched; removed = filed + matched + discarded; skipped = .skipped + .failed.
    public static func summaryLine(_ results: [IngestResult]) -> String
    public static func removeEmptyMemoryDir(projectSlug: String, homeDirectory: URL)
}

/// Result of restoring one memory from the estate back to disk.
public struct RestoreResult: Sendable {
    public enum Outcome: Sendable {
        case restored           // file written with moot_memory_id front matter; estate row untouched
        case skipped(String)
        case failed(String)
    }
    public let location: String
    public let filePath: String
    public let outcome: Outcome
}

/// Restore: writes every active `harness-import/<slug>/<name>` and
/// `harness/<slug>/<name>` row back to ~/.claude/projects/<slug>/memory/<name>
/// with `HarnessMemoryFrontMatter.inject(content, memoryId: id)`. Discovery is
/// one `listMemories(locationPrefix: "harness")` query; rows are deduplicated
/// by id, superseded rows and unsafe locations (`..`, leading dot, extra path
/// segments) are skipped. Estate rows are never mutated or deleted. When
/// discovery throws, the result is exactly one `.failed` entry and nothing is
/// written: a refusal is a failure of the disable, never an empty wing.
/// For a slug with restored files and no captured MEMORY.md row, restore writes a
/// MEMORY.md with pinned bytes (both ports): a front matter block holding only
/// `moot_generated_index: true`, then `# Memory Index`, a blank line, and one
/// `- [<name>](<name>)` line per restored file, sorted by name in byte order.
/// For files a.md and b.md:
/// `---\nmetadata:\n  moot_generated_index: true\n---\n# Memory Index\n\n- [a.md](a.md)\n- [b.md](b.md)\n`.
public enum HarnessMemoryRestore {
    public static func restore(
        homeDirectory: URL,
        daemon: some DaemonClient
    ) async -> [RestoreResult]
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

/// Errors thrown by `LiveDaemonClient` (JSON-RPC 2.0 over loopback HTTP).
public enum DaemonError: Error {
    case httpError(Int)     // non-200 HTTP response code
    case parseError         // body not JSON-RPC 2.0, or a tool result missing a required field
    case refused(code: String, message: String)
                            // the daemon said no: an ARIA v2 refusal frame (HTTP 200, result.isError,
                            // structuredContent.error.code) or a top-level JSON-RPC error (code "rpc_error")
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

// The active estate's database, from the estate catalog (GeniusLocusKit).
let estate = try EstateCatalog.open().active.databaseURL
```

---

*End of Installer Interface.*

## Security repair contract

### External-estate purge boundary

Full uninstall includes each existing external estate's catalog-owned files
and encryption sidecars, preserving the user-controlled directory and unrelated
siblings. Both ports list the actual external paths before interactive
confirmation. The controlled configuration directory is moved last, after
all external owned files succeed. A partial failure reports that some data
may remain and does not claim an atomic purge.

## Changelog

### 2.0.0 — 2026-09-15

Updated the security repair contract and cross-port API guarantees above.


### 1.15.0 -- 2026-09-14
`DaemonClient.updateMemory(id:mutation:note:)` is removed. Harness memory
no longer supersedes or revives a row: a changed file files a fresh row
at the old row's location and leaves the old row untouched, so the
mutation requirement this method existed for is gone. `getMemory(id:)`
remains the only lookup the ingest path needs.

`IngestResult.Outcome.replaced` is retired; a changed file now reports
`.filed`, the same outcome a no-id file already used. The estate gains a
second row for that (slug, filename) pair — the old row is never
mutated. `HarnessMemoryIngest.summaryLine`'s `filed` count drops the
`.replaced` term accordingly.

### 1.14.0 -- 2026-09-09
Harness-memory re-enable identity and paging (Bob's ruling, 2026-09-09; both
ports). `HarnessMemoryRestore.restore(homeDirectory:daemon:)` discovers every
`harness-import/*` and `harness/*` row itself (the `projectSlugs` and `now`
parameters are gone), writes each file with its estate id as
`moot_memory_id` front matter under `metadata:`, and no longer supersedes the
row. New `HarnessMemoryFrontMatter` (`inject` / `strip`, byte-exact, shared
vector with Rust). `HarnessMemoryIngest.ingestFile` lost `isReEnable`: a file
carrying an id is matched to its row by `DaemonClient.getMemory(id:)` (new
protocol requirement); `IngestResult.Outcome.revived` is replaced by
`.matched` and `.replaced`. `LiveDaemonClient.listMemories` pages with
`limit` / `cursor`, restarts on `cursor_stale` / `cursor_expired`, and fetches
records with `memory_ids` batches of 50. `DaemonError.rpcError` is folded into
the new `DaemonError.refused(code:message:)`, which also carries ARIA v2
refusal frames (HTTP 200 with `result.isError`). Minor bump: the protocol
gained a requirement and two signatures changed inside the same feature.

Generated MEMORY.md round trip (reviewer finding 009; both ports).
`HarnessMemoryFrontMatter` gains the keyed forms `inject(_:key:value:)` and
`strip(_:key:)` plus `generatedIndexKey` (`moot_generated_index`); the
memory-id overloads are wrappers. The MEMORY.md restore generates for a slug
carries `moot_generated_index: true` in front matter and lists
`- [<name>](<name>)` lines sorted in byte order, identical bytes in both
ports. `IngestResult.Outcome` gains `.discardedIndex`: a MEMORY.md with that
marker and no memory id is removed without filing, so a disable → enable
cycle no longer adds one estate row per slug. `mootx01 enable harness-memory`
reports the discarded count in its ingest summary.

`HarnessMemoryIngest.summaryLine(_:)` gives the CLI the Rust port's ingest summary
words (filed, matched, discarded indexes, removed, skipped), so a matched file is
never printed as filed. `LiveDaemonClient.listMemories` treats `has_more` true
without a fresh `next_cursor` as `DaemonError.parseError`, matching Rust's
"malformed page": a wing whose tail is unreachable is never returned truncated.

### 1.13.1 -- 2026-09-09
Documented seeder Bool return-value divergence (Swift `Bool` vs Rust `io::Result<bool>`,
W-4): semantics table added to `MootProductIdentity.Settings` section. Both ports
now surface a stderr warning on seed failure (W-5).

### 1.13.0 -- 2026-09-08
R6 setting (2026-09-09): stats-store path is now a changeable setting.
`MootProductIdentity.Settings` added: reads `<config-dir>/config.json`
for `daemon.stats_store`, returns typed values with defaults.
`MootPaths.daemonStatsStoreDefault(dataDir:)` added: pure computed path,
no settings lookup, used by the install seeder.
`MootPaths.daemonStatsStorePath(dataDir:)` now checks `Settings.load`
first and falls back to `daemonStatsStoreDefault`.
`mootx01 install` calls `Settings.seedDefaultsIfAbsent` to write the
default into `config.json` when the key is absent (idempotent).
`mootx01 upgrade` leaves `config.json` untouched.
### 1.12.0 -- 2026-09-08
**EstateOpen funnel (both ports, M3 item 1).** Added `MootInstallerCore.EstateOpen`
(Swift) and `core::estate_open` (Rust) as the single entry point for opening the
estate catalog. Both ports execute the same two steps in the same order:
`windows_base_adoption` then `catalog_open`. The step list is published as
`EstateOpen.steps` (Swift) / `STEPS` (Rust) and verified by a cross-port parity
test reading `apps/mootx01/Tests/Fixtures/estate_open_steps.json`.

**`unlock` flag removed (R5).** `--db` was not in the `unlock` spec; the flag
is removed from both ports. `UnlockCommand.swift` and the Rust `cli.rs`/`parse_unlock`
no longer accept it; `Command::Unlock` carries only `tier`.

**`--http auto` on Swift `serve`.** `ServeCommand.swift` now accepts `--http auto`
(hunt from `MootPaths.defaultResidentPort` upward) alongside `--http <port>` (exact).
Matches the existing Rust behaviour (`HttpMode::Auto`). The `http` property type is
now `String?` instead of `Int?`.

**Stats-store path from configuration (R6).** `ServeCommand` reads the telemetry
store path from `MootPaths.daemonStatsStorePath(dataDir:)` directly rather than the
`ARIA_MCP_STATS_STORE` environment variable. `InstallCommand` no longer injects
`ARIA_MCP_STATS_STORE` into the launchd plist environment; the path is resolved by
the daemon at runtime.

**`EstateOpening` rename (AriaMcpKit Rust, M5-3).** `SqliteOpening` in
`packages/kits/AriaMcpKit/rust/src/estate_registry.rs`, `server.rs`, and
`dream_runner.rs` renamed to `EstateOpening` (name now reflects all backend kinds).
Callers in `apps/mootx01/rust/src/commands/` updated.

**`db delete` confirm flag aligned (I2-2).** Rust `db delete` now uses `--yes`/`-y`
(matching Swift). `--force`/`-f` is rejected. Abort exits 0 in both ports.

**drain/dream help text (W2-4).** `--db` help string for `drain` and `dream` updated
to `--db <name>|<dir>/<name>` matching `serve`, `query`, and `upgrade`.

**`EstateEncryptionBridge.swift` renamed** to `EstateEncryptionAliases.swift`; the
header now describes the file correctly (type aliases + one extension).

### 1.11.1 -- 2026-09-08
Removed stale `MOOTx01DatabaseError` declaration from §4 (the type was
removed in 1.8.0; its presence in the interface section was an oversight).
Reordered changelog newest-first: 1.8.0 and 1.9.0 were appended out of
order; reordered newest-first.

### 1.11.0 -- 2026-09-08
The Rust `mootx01` commands run on the estate catalog
(`genius_locus_kit::EstateCatalog`): `serve`, `drain`, `dream`, `query`,
`upgrade` and `db` take `--db <name>|<dir>/<name>`; `status` and
`codex-memory doctor` report the catalog's active record; `db` gains
`register` and `unregister` and `delete` refuses the active estate;
`install` records the `--no-encrypt` choice in the default estate's
manifest and reuses or replaces the default record's files; `uninstall`
inventories the catalog's records. The daemon quiesce in `upgrade` is
decided by the estate's own PID marker (`with_resident_daemon_quiesced(
estate_pid_file, step, daemon, work)`, `with_resident_serving`,
`resident_serves`); `upgrade` folds a legacy `no-encrypt` marker into the
manifest and refreshes the manifest after the schema step. Retired from the
Rust port: `MOOTX01_DATA_DIR` (the service unit and task carry no
data-directory value; `core::service::daemon_unit(binary, vault_on)`,
`mgr_unit(binary, token)`, `daemon_task_command(binary, vault_on)`,
`mgr_task_command(binary, token)` are infallible), `core::paths::
{ResidentDataDir, resident_data_dir, resident_data_dir_from,
is_resident_estate, estate_sqlite_path, active_estate, set_active_estate,
config_json_path}`, `core::service::{DaemonRegistration,
daemon_registration, daemon_registration_from_unit_file,
data_dir_from_unit, data_dir_from_task_command, hidden_launcher_path,
is_cmd_safe, is_systemd_safe, DATA_DIR_ENV_VAR}`, `core::encrypt_optout`,
`core::mcp_ownership::OVERRIDE_ENV_KEYS` (an MCP entry is foreign by its
shape or a `--db` argument only), and `install::{default_estate_exists,
apply_reuse(data), apply_replace(data)}` in favour of `estate_exists(
database)`, `apply_reuse(record, configuration)`, `apply_replace(files,
configuration)` and `replaceable_estate_files(record)`; `uninstall::
data_inventory(default_database, named_databases, configuration)`. moot-mgr
reads the configuration directory from `moot_product_identity`.

### 1.10.0 -- 2026-09-08
The community daemon (`mootx01-daemon`, the direct provider shell and the
nested helper) opens the estate catalog's active record once through
GeniusLocusKit (`CommunityEstateHost(record:kit:ownerIdentifier:identityKeyStore:)`,
with `handle()`, `estate()` and `databaseExists` for the coordinators);
`CommunityEstateLifecycleCoordinator`, `CommunityCaptureCoordinator` and
`CommunityReviewCoordinator` take `(host:layoutURL:)` and share that open;
`CommunityResidentMain.makeCommunityDispatch(host:layoutURL:state:...)`
replaces the layout-directory, owner and key-provider form. The daemon's
second database (`glk-estate.sqlite`) and its hand-computed
`~/Library/Application Support/MOOTx01/estate.sqlite` are gone; sidecar
state lives in `<configuration directory>/community-daemon/`. The census's
canonical estate is the app family's catalog default record in the group
container (`…/com.mootx01.ce/databases/default/estate.sqlite`), spelled from
`MootProductIdentity.Storage`. DECISION_INSTALL_TAKEOVER_2026-09-08.

### 1.9.0 -- 2026-09-08
Key custody and the at-rest open posture leave MootInstallerCore.
`EstateKeyProvider`, its `resolveOpenPosture`, `OpenPosture`, `PostureError`
and `KeyProviderError` are removed; the decision is GeniusLocusKit's
`EstateOpenPosture` (GENIUSLOCUSKIT_SPEC § ESTATE_OPEN_POSTURE), which every
mootx01 command, the resident daemon and the app call. MootInstallerCore
keeps `EstateEncryptionMigrator` (the EstateEncryption library under the
commands' spelling) and `DaemonControl.launchd(homeDirectory:)`, and no longer
depends on PersistenceKitSQLite. `DbDeleteCommand` disposes the estate key
through `EstateOpenPosture.disposeKey`.

### 1.8.0 -- 2026-09-08
Estate location leaves MootInstallerCore. `DatabaseManager` and
`MOOTx01DatabaseError` are removed: estate lifecycle (create, register,
unregister, list, open, delete) runs on the GeniusLocusKit `EstateCatalog`
(spec § ESTATE_CATALOG) and `mootx01 db` is its command surface; the
`config.json` active-estate pointer is gone with it. `MootPaths` loses
`dataDirEnvVar`, `estateFileName`, `resolveDataDirectory(environment:homeDirectory:)`
and `estateURL(in:)`: no environment value selects an estate or a data
directory, and the configuration directory is
`EstateCatalog.configurationDirectory`. `ResidentDaemonQuiesce` is documented
as it is: the estate PID marker decides the quiesce, with a `residentServes:`
form for callers that already know. `DataRetention` takes database URLs and
the configuration directory (`estateExists(databaseURL:)`,
`applyReuse(configurationDirectory:)`, `applyReplace(estateFiles:configurationDirectory:)`,
`dataInventory(defaultDatabaseURL:namedDatabaseURLs:configurationDirectory:)`).

### 1.7.0 -- 2026-09-07
The resident data directory comes from the daemon's service registration,
not the platform default. `mootx01 install` bakes `MOOTX01_DATA_DIR` into
the launchd plist / systemd unit / Task Scheduler action, so
`MootPaths.residentDataDirectory(homeDirectory:)` now reads the daemon
plist's `EnvironmentVariables["MOOTX01_DATA_DIR"]` and
`core::paths::resident_data_dir` reads the systemd unit's
`Environment=MOOTX01_DATA_DIR=` line (Linux) or the `mootx01` task's
`set MOOTX01_DATA_DIR=` command (Windows). New types
`MootPaths.ResidentDataDirectory` / `core::paths::ResidentDataDir`
(`directory` | `unreadableRegistration`): a registration that exists but
cannot be parsed makes every estate resident, so every upgrade step
quiesces rather than migrate under a daemon that may hold the estate open.
Changed signatures: `residentDataDirectory(homeDirectory:)` returns
`ResidentDataDirectory`; `isResidentEstate(dataDirectory:residentDataDirectory:)`
and `ResidentDaemonQuiesce.run` take it. New pure surface:
`MootPaths.registeredResidentDataDirectory(homeDirectory:daemonPlist:)`,
`core::paths::resident_data_dir_from`, `core::service::DaemonRegistration`,
`core::service::daemon_registration`, `daemon_registration_from_unit_file`,
`data_dir_from_unit`, `data_dir_from_task_command`, `hidden_launcher_path`.

### 1.6.1 -- 2026-09-04
`mootx01 upgrade` never creates content. The Rust distilled-representation
convergence step now opens the estate through `EstateRegistry::new_sqlite_for_maintenance`
instead of `new_sqlite`, which skips `seed_wings_non_fatal` and
`register_default_minter_non_fatal`. Upgrade is a migration vehicle: it
converges what already exists and creates none. Default-wing seeding belongs
to `provision` and `serve` only. This matches the Swift port, which opens
through the bare `GeniusLocusKit.open(storage:owner:)` path (no
`seedDefaultWings` call). No new public API surface.

### 1.6.0 -- 2026-09-03
`mootx01 upgrade` quiesces the resident daemon only when the data directory
it is upgrading is the resident estate. Every backfill step in both ports
now routes through one helper (`ResidentDaemonQuiesce.run` /
`with_resident_daemon_quiesced`) that compares the resolved data directory
against `MootPaths.residentDataDirectory` / `paths::resident_data_dir` with
symlinks resolved; a clone reached through `MOOTX01_DATA_DIR` is upgraded
with the daemon left running and one line saying so. New public API:
`MootPaths.residentDataDirectory(homeDirectory:)`,
`MootPaths.isResidentEstate(dataDirectory:residentDataDirectory:)`,
`ResidentDaemonQuiesce`.

### 1.5.0 -- 2026-08-27
Renamed one public entrypoint. `LaunchAgent.honestServerStatus(registration:port:providerReportedState:)`
is now `LaunchAgent.observedServerStatus(registration:port:providerReportedState:)`.

Behaviour is unchanged: a registration, PID, or answering port is still
never reported as a running or ready server, and the provider's own
reported arbiter state still passes through verbatim. The new name states
what the function does — it reports observations and never infers
readiness from them — where the old one described the intent behind that
rule rather than the behaviour.

MINOR rather than PATCH because the public symbol changed. There is no
deprecated alias: the callers are `mootx01 status` and this repository's
own tests, all migrated in the same change, and a forwarding shim would
be the bridge pattern the house rules prohibit.

### 1.4.0 -- 2026-08-18
Added MACD-3B3 authenticated coexistence surface.  New public types and
entrypoints in `MootInstallerCore`:

- **`OwnershipProbeOutcome` computed properties (MACD-3B3 C2/C3/C4).**
  `requiresClientOnlyInstall: Bool` — `true` only for `.healthy(.bundled)`;
  the single gate for skipping daemon + bundle-plist registration.
  `blocksInstallByVersionMismatch: Bool` — `true` for `.incompatible`; no
  second provider is started.
  `normalInstallProceeds: Bool` — `true` for `.absent` and `.unauthenticated`
  (both allow normal install; `.unauthenticated` never kills the running process).

- **`LaunchAgent.authenticatedBundledOwner(outcome:) -> String?` (C5).**
  The single authoritative format point mapping a `ProviderOwnershipProbe`
  outcome into the `providerReportedState` string for `observedServerStatus`.
  `.absent` returns `nil` (fall through to registration/port observation).
  Healthy, incompatible, and unauthenticated outcomes produce non-nil strings
  carrying the provider's own wire vocabulary verbatim — no second copy of the
  arbiter vocabulary ("parallel copies fail").

- **`mootx01 install` coexistence gate (C2/C3/C4).**
  `ProviderOwnershipProbe` runs before every daemon registration decision
  inside the `!noDaemon` block.  Healthy bundled owner → client-only install
  (MCP client wiring only; `LaunchAgent.installDaemon` and
  `installDaemonBundleIfPresent` are both skipped; output: "Using
  MOOTx01-App resident provider").  Incompatible owner → verdict surfaced
  verbatim; no registration; no second provider.  Absent or unauthenticated
  → normal install path; unauthenticated warns but never kills.

- **`mootx01 upgrade` coexistence gate (C2/C4).**
  `UpgradeCommand.convergeDaemonBundle` runs the same probe before
  `LaunchAgent.installDaemonBundleDisabled`.  Healthy bundled → bundle
  convergence silently skipped.  Incompatible → verdict logged; return early.

- **`mootx01 status` provider-verbatim wire (C5).**
  `StatusCommand` calls `ProviderOwnershipProbe().detect()` and threads its
  result through `LaunchAgent.authenticatedBundledOwner(outcome:)` into
  `observedServerStatus`.  The `providerReportedState: nil` placeholder (MACD-2c2)
  is replaced with the live probe result.  Status never equates
  registration/port/PID with readiness.

Minor-version bump: additive surface; all existing signatures unchanged.

### 1.3.0 -- 2026-08-17

- **Daemon provider bundle artifact (MACD-2c2).** The macOS pkg payload and
  release archive gain the signed app-like daemon bundle
  `Mootx01DaemonProvider.app` (bundle id
  `com.codedaptive.mootx01.macos.daemonprovider`), wrapped from the
  `mootx01-daemon` thin shell and staged inside the `bin/` payload so it
  rides the existing postinstall relocation to
  `~/.mootx01/bin/Mootx01DaemonProvider.app`. All artifact spellings live in
  ONE Swift constant surface — `MootInstallerCore.DaemonBundle`
  (`bundleName`, `executableName`, `bundleIdentifier`, `launchAgentLabel`,
  `residentModeArgument`, `installedBundleURL`, `bundleExecutableURL`,
  `launchAgentPlistURL`, `programArguments`, `ownedArtifactPaths`) — and the
  Makefile / distribution/macos/build-pkg.sh / .github/workflows/release.yml
  spellings are parity-checked against it by LaunchAgentTests.

- **LaunchAgent contract.** The bundle-form daemon plist
  (`com.codedaptive.mootx01.daemon`, distinct from the retained legacy
  raw-serve `com.mootx01.daemon`) carries ProgramArguments pointing INSIDE
  the bundle: `[…/Contents/MacOS/Mootx01DaemonProvider, resident]` — never a
  raw binary with `serve`. It is the DISABLED-install variant
  (`RunAtLoad=false`, `KeepAlive=false`); `LaunchAgent.makeDaemonBundlePlist`
  is the source of truth and `LaunchAgent.installDaemonBundleDisabled`
  writes it, verifies it by READBACK, and never bootstraps. The `resident`
  mode exits 4 (`resident-unavailable`) until estate hosting activates
  (MACD-3); the disabled install makes that state unreachable in production.
  Upgrade retains the legacy artifact (plist, label, and running job
  untouched) until the bundle provider proves authenticated readiness.

- **Observed status vocabulary.** `LaunchAgent.observedServerStatus(registration:port:providerReportedState:)`
  plus `DaemonRegistrationObservation` / `DaemonPortObservation`: a
  registration, PID, or answering port is NEVER reported as a running/ready
  server; the provider's own reported arbiter state passes through verbatim
  (the status surface owns no second copy of the arbiter vocabulary).
  `mootx01 status` now reports through this surface.

- **Census dispositions and migration receipt.** `mootx01 install` registers
  the bundle disabled when present and runs the provider's read-only
  `census` mode (class labels, digests, conservative disposition; the five
  dispositions are `none-found` / `one-valid` / `already-converged` /
  `byte-identical-duplicates` / `multiple-estates-hard-stop`, with
  unverifiable identity always classifying toward the hard stop). The
  migration receipt (`MOOTX01-MIGRATION-RECEIPT-v1`, staged-before-rename,
  committed after) lives in the provider directory and is never touched by
  the installer.

- **Uninstall preservation.** Uninstall removes ONLY owned artifacts
  (`DaemonBundle.ownedArtifactPaths`: the bundle and its registration plist,
  plus the previously owned binaries/plists). Estate databases, migration
  receipts, backups, and Keychain credentials (K_install, estate keys)
  survive every uninstall; the explicit data-removal flow is separate,
  typed-confirmation-gated, and never touches non-owned census candidates.


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

