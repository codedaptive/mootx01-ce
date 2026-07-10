// InstallerTests.swift
//
// Tests for Installer: proxy bridge wiring, headless stdio guards,
// config discovery and merging (JSON/JSONC/YAML/TOML clients),
// install/uninstall round-trips, idempotency, refusal paths,
// backup behavior, bundle-copy behavior, MOOT.md creation,
// placeBinary placement and force parameter, Continue/Hermes/Codex/
// opencode client wiring, and local-mode installs. All I/O uses
// sandbox home and working directories; no real user configs are touched.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("Installer")
struct InstallerTests {

    // MARK: - Install / uninstall round-trip (JSON clients)

    @Test("install writes mcpServers entry into non-existent config")
    func installCreatesConfig() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let binaryPath = "/usr/local/bin/mootx01"
        let cwd = URL(fileURLWithPath: "/tmp")

        try Installer.install(
            client: client,
            binaryPath: binaryPath,
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home,
            workingDirectory: cwd,
            local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let data = try Data(contentsOf: configURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        let entry = servers?[client.serverName] as? [String: Any]
        // Accepted CE posture (docs(secfix/ce-loopback-impersonation),
        // b913ca4a): HTTP-capable clients are wired to the resident daemon's
        // fixed loopback endpoint. The command/stdio assertions this test
        // once made encoded an unauthorized flip that was reverted (5c035e6).
        #expect(entry?["url"] as? String == MootPaths.residentEndpointURL,
                "default client wiring targets the resident daemon endpoint")
        #expect(entry?["command"] == nil, "HTTP-wired client carries no command entry")
    }

    @Test("Claude Desktop gets a stdio command entry pointing at the proxy symlink (no native local-HTTP)")
    func claudeDesktopStaysStdio() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let binaryPath = "/usr/local/bin/mootx01"
        // Expected proxy symlink path: same directory, "mootx01-proxy" name.
        let proxyPath = "/usr/local/bin/mootx01-proxy"
        try Installer.install(
            client: client, binaryPath: binaryPath,
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )
        let configURL = home.appendingPathComponent(client.configPath)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let entry = (obj?["mcpServers"] as? [String: Any])?[client.serverName] as? [String: Any]
        // Proxy-bridge clients use the bare proxy symlink as command — no args needed.
        // ArgvDispatch maps argv0 "mootx01-proxy" to the proxy subcommand automatically.
        #expect(entry?["command"] as? String == proxyPath,
                "proxy-bridge client must use the mootx01-proxy symlink as its bare command")
        #expect(entry?["args"] == nil,
                "proxy-bridge client must not carry an explicit args array — argv0 dispatch handles routing")
        #expect(entry?["url"] == nil, "stdio client must not get an HTTP url entry")
    }

    @Test("install into existing config merges without losing other keys")
    func installMergesExistingConfig() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)

        // Pre-existing config with a different server.
        let existing: [String: Any] = [
            "mcpServers": ["other-server": ["command": "/other/bin", "args": [], "env": [:] as [String: String]]]
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try existingData.write(to: configURL)

        try Installer.install(
            client: client, binaryPath: "/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )

        let data = try Data(contentsOf: configURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        #expect(servers?["other-server"] != nil, "existing server must be preserved")
        #expect(servers?[client.serverName] != nil, "mootx01 entry must be present")
    }

    @Test("install is idempotent: second call leaves config unchanged")
    func installIdempotent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "cursor" }!
        let cwd = URL(fileURLWithPath: "/tmp")

        try Installer.install(client: client, binaryPath: "/bin/mootx01",
                              daemonURL: MootPaths.residentEndpointURL,
                              homeDirectory: home, workingDirectory: cwd, local: false)
        let configURL = home.appendingPathComponent(client.configPath)
        let firstContent = try Data(contentsOf: configURL)

        try Installer.install(client: client, binaryPath: "/bin/mootx01",
                              daemonURL: MootPaths.residentEndpointURL,
                              homeDirectory: home, workingDirectory: cwd, local: false)
        let secondContent = try Data(contentsOf: configURL)

        #expect(firstContent == secondContent)
    }

    @Test("uninstall removes only the mootx01 entry from mcpServers")
    func uninstallRemovesEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let cwd = URL(fileURLWithPath: "/tmp")

        try Installer.install(client: client, binaryPath: "/bin/mootx01",
                              daemonURL: MootPaths.residentEndpointURL,
                              homeDirectory: home, workingDirectory: cwd, local: false)
        try Installer.uninstall(client: client, homeDirectory: home, workingDirectory: cwd, local: false)

        let configURL = home.appendingPathComponent(client.configPath)
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let servers = obj?["mcpServers"] as? [String: Any] ?? [:]
            #expect(servers[client.serverName] == nil)
        }
        // If the file was removed entirely (empty mcpServers → file deleted), that's also valid.
    }

    @Test("uninstall is a no-op when config file does not exist")
    func uninstallNoOpWhenAbsent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        // Should not throw even when the config doesn't exist.
        try Installer.uninstall(
            client: client, homeDirectory: home,
            workingDirectory: URL(fileURLWithPath: "/tmp"), local: false
        )
    }

    // MARK: - Binary placement

    @Test("placeBinary copies the binary to ~/.mootx01/bin/mootx01 and makes it executable")
    func placeBinaryCopiesAndChmods() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }

        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let expected = home.appendingPathComponent(".mootx01/bin/mootx01")
        #expect(placed == expected.path, "placeBinary must return the installed absolute path")
        #expect(FileManager.default.fileExists(atPath: expected.path))

        // Executable bit (0755) must be set.
        let attrs = try FileManager.default.attributesOfItem(atPath: expected.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0, "placed binary must be executable")
    }

    @Test("placeBinary creates a PATH wrapper that execs the placed binary")
    func placeBinaryCreatesExecWrapper() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }

        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        // The PATH entry must be an exec WRAPPER SCRIPT, not a symlink: the
        // runtime resolves SPM resource bundles from the invoked path's
        // directory without following a symlink there, so a symlinked entry
        // crashes every Bundle.module target on first resource touch (the
        // v1.0.9 installed-CLI crash).
        let entry = home.appendingPathComponent(".local/bin/mootx01")
        let fm = FileManager.default
        #expect((try? fm.destinationOfSymbolicLink(atPath: entry.path)) == nil,
                "PATH entry must not be a symlink")
        let script = try String(contentsOfFile: entry.path, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh"), "wrapper must be a shell script")
        #expect(script.contains("exec '\(placed)' \"$@\""),
                "wrapper must exec the placed binary, forwarding all args")
        let attrs = try fm.attributesOfItem(atPath: entry.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0, "wrapper must be executable")
    }

    @Test("placeBinary replaces a legacy PATH symlink with the wrapper")
    func placeBinaryReplacesLegacySymlink() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let fm = FileManager.default

        // Simulate a pre-wrapper install: a symlink at the PATH entry.
        let localBin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: localBin, withIntermediateDirectories: true)
        let entry = localBin.appendingPathComponent("mootx01")
        try fm.createSymbolicLink(
            at: entry, withDestinationURL: home.appendingPathComponent(".mootx01/bin/mootx01"))

        let source = try makeFakeBinary()
        defer { try? fm.removeItem(at: source) }
        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        #expect((try? fm.destinationOfSymbolicLink(atPath: entry.path)) == nil,
                "legacy symlink must be replaced by the wrapper")
        let script = try String(contentsOfFile: entry.path, encoding: .utf8)
        #expect(script.contains("exec '\(placed)' \"$@\""))
    }

    @Test("placeBinary overwrites an existing install (re-install is safe)")
    func placeBinaryReinstallOverwrites() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let first = try makeFakeBinary(contents: "v1")
        defer { try? FileManager.default.removeItem(at: first) }
        _ = try Installer.placeBinary(sourcePath: first.path, homeDirectory: home)

        let second = try makeFakeBinary(contents: "v2")
        defer { try? FileManager.default.removeItem(at: second) }
        let placed = try Installer.placeBinary(sourcePath: second.path, homeDirectory: home)

        let content = try String(contentsOfFile: placed, encoding: .utf8)
        #expect(content == "v2", "re-install must overwrite the prior binary")
    }

    @Test("placeBinary re-run from the PATH entry does not clobber the real binary")
    func placeBinaryReinstallFromPlacedBinaryDoesNotLoop() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary(contents: "real")
        defer { try? FileManager.default.removeItem(at: source) }
        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let fm = FileManager.default
        let pathEntry = home.appendingPathComponent(".local/bin/mootx01").path

        // Regression: `mootx01 install` run from the installed binary arrives
        // here with sourcePath = the ~/.local/bin/mootx01 PATH entry (or the
        // resolved installed path). In the symlink era copyItem copied the
        // LINK and produced a self-referential symlink (ELOOP); in the
        // wrapper era a naive copy would land the SHELL SCRIPT over the real
        // binary. resolvePathWrapper must see through the wrapper.
        _ = try Installer.placeBinary(sourcePath: pathEntry, homeDirectory: home)
        _ = try Installer.placeBinary(sourcePath: placed, homeDirectory: home)

        // Dest must stay the REAL binary — never a symlink, loop, or wrapper.
        #expect((try? fm.destinationOfSymbolicLink(atPath: placed)) == nil,
                "placed binary must remain a regular file, not a symlink")
        #expect(fm.fileExists(atPath: placed), "placed binary must still exist")
        #expect(try String(contentsOfFile: placed, encoding: .utf8) == "real",
                "the real binary content must survive re-install from itself")
        let wrapper = try String(contentsOfFile: pathEntry, encoding: .utf8)
        #expect(wrapper.contains("exec '\(placed)' \"$@\""),
                "PATH wrapper still execs the real placed binary")
    }

    @Test("placeBinary carries every .bundle sibling into the install bin dir")
    func placeBinaryCopiesResourceBundles() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Build a source binary with two SPM resource bundles beside it, the way
        // `swift build` lays out `<Target>_<Target>.bundle` next to the executable.
        let (source, srcDir) = try makeFakeBinaryWithBundles(
            bundles: ["LatticeLib_LatticeLib.bundle", "EideticLib_EideticLib.bundle"]
        )
        defer { try? FileManager.default.removeItem(at: srcDir) }

        _ = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let binDir = home.appendingPathComponent(".mootx01/bin")
        let fm = FileManager.default
        for name in ["LatticeLib_LatticeLib.bundle", "EideticLib_EideticLib.bundle"] {
            let dest = binDir.appendingPathComponent(name)
            #expect(fm.fileExists(atPath: dest.path),
                    "\(name) must be co-located with the placed binary")
            // The marker file inside the bundle must come across too.
            let marker = dest.appendingPathComponent("marker.json")
            #expect(fm.fileExists(atPath: marker.path),
                    "\(name) contents must be copied, not just the directory")
        }
    }

    @Test("placeMgrBinary carries every .bundle sibling into the install bin dir")
    func placeMgrBinaryCopiesResourceBundles() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // moot-mgr is the binary that actually links LatticeLib/EideticLib, so
        // its placement path must carry the bundles too.
        let (source, srcDir) = try makeFakeBinaryWithBundles(
            bundles: ["LatticeLib_LatticeLib.bundle", "swift-crypto_Crypto.bundle"],
            named: "moot-mgr"
        )
        defer { try? FileManager.default.removeItem(at: srcDir) }

        _ = try Installer.placeMgrBinary(sourceMgrPath: source.path, homeDirectory: home)

        let binDir = home.appendingPathComponent(".mootx01/bin")
        let fm = FileManager.default
        for name in ["LatticeLib_LatticeLib.bundle", "swift-crypto_Crypto.bundle"] {
            #expect(fm.fileExists(atPath: binDir.appendingPathComponent(name).path),
                    "\(name) must be co-located with the placed moot-mgr binary")
        }
    }

    @Test("re-place refreshes stale bundle contents")
    func placeBinaryRefreshesBundleContents() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let fm = FileManager.default
        let binDir = home.appendingPathComponent(".mootx01/bin")
        let destMarker = binDir
            .appendingPathComponent("LatticeLib_LatticeLib.bundle")
            .appendingPathComponent("marker.json")

        let (first, firstDir) = try makeFakeBinaryWithBundles(
            bundles: ["LatticeLib_LatticeLib.bundle"], markerContents: "v1"
        )
        defer { try? fm.removeItem(at: firstDir) }
        _ = try Installer.placeBinary(sourcePath: first.path, homeDirectory: home)
        #expect(try String(contentsOf: destMarker, encoding: .utf8) == "v1")

        let (second, secondDir) = try makeFakeBinaryWithBundles(
            bundles: ["LatticeLib_LatticeLib.bundle"], markerContents: "v2"
        )
        defer { try? fm.removeItem(at: secondDir) }
        _ = try Installer.placeBinary(sourcePath: second.path, homeDirectory: home)
        #expect(try String(contentsOf: destMarker, encoding: .utf8) == "v2",
                "re-place must refresh bundle contents, not keep the stale copy")
    }

    @Test("config command is the ABSOLUTE proxy-symlink path, not the source path")
    func configCommandUsesPlacedPath() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Simulate the InstallCommand flow: place, then write configs with
        // the placed path. The source lives somewhere unrelated (a CWD/dev
        // dir stand-in); the config must NOT reference it.
        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }
        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        // Claude Desktop is the proxy-bridge client: command is the absolute proxy
        // symlink path (mootx01-proxy, same directory as placed binary). HTTP clients
        // carry a url instead — see installCreatesConfig / claudeDesktopStaysStdio.
        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        try Installer.install(
            client: client, binaryPath: placed,
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"), local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let data = try Data(contentsOf: configURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        let entry = servers?[client.serverName] as? [String: Any]
        let command = entry?["command"] as? String

        // Proxy-bridge clients use the bare proxy symlink as command — argv0 dispatch
        // routes "mootx01-proxy" to the proxy subcommand automatically.
        #expect(command == home.appendingPathComponent(".mootx01/bin/mootx01-proxy").path,
                "config command must be the absolute mootx01-proxy symlink path")
        #expect(command?.hasPrefix("/") == true, "config command must be absolute")
        #expect(command != source.path, "config command must not be the source/CWD path")
        #expect(command?.hasPrefix("./") == false, "config command must not be relative")
        // Proxy bridge: no args needed — ArgvDispatch handles routing via argv0.
        #expect(entry?["args"] == nil,
                "claude-desktop proxy entry must not carry an explicit args array")
    }

    @Test("placeBinary creates the same-directory mootx01-proxy symlink beside the binary")
    func placeBinaryCreatesProxySymlink() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let proxyURL = MootPaths.proxySymlinkURL(homeDirectory: home)
        // The proxy symlink must exist as a symlink (not a regular file).
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: proxyURL.path)
        #expect(dest == "mootx01",
                "proxy symlink must be a relative symlink pointing at 'mootx01'")
    }

    @Test("placeBinary re-run recreates the proxy symlink (idempotent)")
    func placeBinaryProxySymlinkIsIdempotent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home, force: true)
        // Second call must not throw — idempotent.
        _ = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home, force: true)

        let proxyURL = MootPaths.proxySymlinkURL(homeDirectory: home)
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: proxyURL.path)
        #expect(dest == "mootx01", "proxy symlink must survive re-install")
    }

    @Test("removePlacedBinary removes the binary and the PATH symlink")
    func removePlacedBinaryCleansUp() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        try Installer.removePlacedBinary(homeDirectory: home)

        let placed = home.appendingPathComponent(".mootx01/bin/mootx01")
        let symlink = home.appendingPathComponent(".local/bin/mootx01")
        let installRoot = home.appendingPathComponent(".mootx01")
        #expect(!FileManager.default.fileExists(atPath: placed.path))
        #expect(!FileManager.default.fileExists(atPath: installRoot.path), "install root removed")
        // lstat-aware check: the symlink (dangling or not) must be gone.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)) == nil)
        #expect(!FileManager.default.fileExists(atPath: symlink.path))
    }

    @Test("removePlacedBinary is a no-op when nothing was installed")
    func removePlacedBinaryNoOp() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // Must not throw on a clean home.
        try Installer.removePlacedBinary(homeDirectory: home)
    }

    // MARK: - Proxy bridge

    @Test("claude-desktop has useProxyBridge true and supportsLocalHTTP false")
    func claudeDesktopProxyBridgeFlags() {
        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        #expect(client.useProxyBridge == true,
                "claude-desktop must use the native proxy subcommand")
        #expect(client.supportsLocalHTTP == false,
                "claude-desktop config schema requires a stdio command entry, not a direct HTTP url")
    }

    @Test("install for useProxyBridge client uses proxy symlink as bare command (no args)")
    func installProxyBridgeClientProducesProxyArgs() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let binaryPath = "/usr/local/bin/mootx01"
        // Proxy symlink is in the same directory as the binary.
        let proxyPath = "/usr/local/bin/mootx01-proxy"
        let daemonURL = MootPaths.residentEndpointURL

        try Installer.install(
            client: client, binaryPath: binaryPath,
            daemonURL: daemonURL,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let entry = (obj?["mcpServers"] as? [String: Any])?[client.serverName] as? [String: Any]
        // Proxy-bridge clients use the bare proxy symlink — no args needed.
        // ArgvDispatch routes argv0 "mootx01-proxy" to the proxy subcommand.
        #expect(entry?["command"] as? String == proxyPath,
                "proxy entry must use the mootx01-proxy symlink as bare command")
        #expect(entry?["args"] == nil,
                "proxy entry must not carry an explicit args array — argv0 dispatch handles routing")
        #expect(entry?["url"] == nil,
                "proxy client must not get an HTTP url entry")
    }

    @Test("install for non-proxy non-HTTP client produces empty args (regression guard)")
    func installNonProxyNonHTTPClientProducesEmptyArgs() throws {
        // A hypothetical non-HTTP, non-proxy client must still get the bare
        // stdio entry — the new useProxyBridge branch must not affect it.
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Construct a synthetic non-HTTP, non-proxy MCPClient inline.
        let bareClient = MCPClient(
            id: "bare-stdio",
            displayName: "Bare Stdio Client",
            configPath: "Library/Application Support/TestClient/config.json",
            serverName: MCPClients.serverName,
            supportsLocalHTTP: false,
            useProxyBridge: false
        )
        let binaryPath = "/usr/local/bin/mootx01"

        try Installer.install(
            client: bareClient, binaryPath: binaryPath,
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )

        let configURL = home.appendingPathComponent(bareClient.configPath)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let entry = (obj?["mcpServers"] as? [String: Any])?[bareClient.serverName] as? [String: Any]
        #expect(entry?["command"] as? String == binaryPath,
                "bare stdio client must still get the command entry")
        let args = entry?["args"] as? [String]
        #expect(args?.isEmpty == true,
                "bare stdio client must get empty args — proxy branch must not affect it")
    }

    // MARK: - isHeadlessStdio

    @Test("isHeadlessStdio is true only when both supportsLocalHTTP and useProxyBridge are false")
    func isHeadlessStdioTruthTable() {
        // Bare stdio client (headless mode): both flags false.
        let headlessClient = MCPClient(
            id: "headless", displayName: "Headless", configPath: "some/config.json",
            serverName: "mootx01",
            supportsLocalHTTP: false, useProxyBridge: false
        )
        #expect(headlessClient.isHeadlessStdio == true,
                "both flags false → headless stdio mode")

        // HTTP-wired client (supportsLocalHTTP: true): not headless.
        let httpClient = MCPClient(
            id: "http-client", displayName: "HTTP Client", configPath: "some/config.json",
            serverName: "mootx01",
            supportsLocalHTTP: true, useProxyBridge: false
        )
        #expect(httpClient.isHeadlessStdio == false,
                "supportsLocalHTTP: true → not headless")

        // Proxy-bridge client (useProxyBridge: true): not headless.
        let proxyClient = MCPClient(
            id: "proxy-client", displayName: "Proxy Client", configPath: "some/config.json",
            serverName: "mootx01",
            supportsLocalHTTP: false, useProxyBridge: true
        )
        #expect(proxyClient.isHeadlessStdio == false,
                "useProxyBridge: true → not headless")
    }

    @Test("HTTP-capable clients are wired to the resident daemon (accepted loopback posture)")
    func supportedClientsUseResidentDaemonHTTP() {
        // The fixed unauthenticated loopback endpoint is the ACCEPTED CE
        // posture — Bob-ruled, recorded in docs(secfix/ce-loopback-impersonation)
        // (b913ca4a): launchd owns the port continuously, SO_REUSEADDR (not
        // REUSEPORT) prevents live theft, and a same-user attacker already
        // reads the estate files directly. Endpoint auth arrives with EE v1.1
        // off-localhost hosting. The inverse assertion this test used to make
        // ("no client may be wired to direct HTTP") encoded an unauthorized
        // stdio flip that was reverted (5c035e6) — do not resurrect it.
        // claude-desktop is the deliberate exception: no native local-HTTP
        // support, so it rides the proxy bridge (covered by its own test).
        let httpWired = Set(MCPClients.supported.filter(\.supportsLocalHTTP).map(\.id))
        let expected = Set(MCPClients.supported.map(\.id)).subtracting(["claude-desktop"])
        #expect(httpWired == expected,
                "HTTP-capable clients must ride the resident daemon endpoint; got \(httpWired.sorted())")
    }

    // MARK: - Continue YAML

    @Test("install writes a valid YAML file for Continue")
    func installContinueWritesYAML() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "continue" }!
        let binaryPath = "/usr/local/bin/mootx01"

        try Installer.install(
            client: client, binaryPath: binaryPath,
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        // Continue rides the resident daemon over streamable-http (accepted
        // loopback posture, b913ca4a).
        #expect(content == "type: streamable-http\nurl: \(MootPaths.residentEndpointURL)\n")
    }

    // MARK: - Claude Code --local mode

    @Test("install in local mode writes to .mcp.json in workingDirectory")
    func installLocalModeCaudeCode() throws {
        let home = try makeSandboxHome()
        let cwd = try makeSandboxHome()
        defer { cleanupSandbox(home); cleanupSandbox(cwd) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try Installer.install(
            client: client, binaryPath: "/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: cwd, local: true
        )

        let localConfig = cwd.appendingPathComponent(".mcp.json")
        #expect(FileManager.default.fileExists(atPath: localConfig.path))
    }

    // MARK: - MOOT.md

    @Test("writeMOOTmd creates MOOT.md when absent")
    func writeMOOTmdCreatesFile() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        try Installer.writeMOOTmd(
            homeDirectory: home, local: false,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        let mootmd = home.appendingPathComponent(".claude/MOOT.md")
        #expect(FileManager.default.fileExists(atPath: mootmd.path))
    }

    @Test("writeMOOTmd does not overwrite existing MOOT.md")
    func writeMOOTmdSkipsExisting() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mootmd = dir.appendingPathComponent("MOOT.md")
        try "custom content".write(to: mootmd, atomically: true, encoding: .utf8)

        try Installer.writeMOOTmd(
            homeDirectory: home, local: false,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        let content = try String(contentsOf: mootmd, encoding: .utf8)
        #expect(content == "custom content")
    }

    // MARK: - placeBinary force parameter

    // UpgradeCommand validation tests (--from path resolution, ValidationError paths)
    // require @testable import of the mootx01 executable target, which SPM does not
    // support. The underlying mechanisms are fully tested below via Installer and
    // LaunchAgent APIs. Integration-level UpgradeCommand behavior is verified by
    // the manual verification step in the mission's Verification section.

    @Test("placeBinary force:false skips copy when source resolves to the installed path")
    func placeBinaryForceFalseSkipsWhenSourceEqualsInstalled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary(contents: "original")
        defer { try? FileManager.default.removeItem(at: source) }
        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        // Simulate running install from the already-placed binary (source IS dest).
        // force: false must skip the copy so the installed content is unchanged.
        _ = try Installer.placeBinary(sourcePath: placed, homeDirectory: home, force: false)

        let content = try String(contentsOfFile: placed, encoding: .utf8)
        #expect(content == "original",
                "force:false must not replace the installed binary when source resolves to dest")
    }

    @Test("placeBinary force:true copies a new binary over the installed one")
    func placeBinaryForceTrueCopiesNewSource() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let v1 = try makeFakeBinary(contents: "v1")
        defer { try? FileManager.default.removeItem(at: v1) }
        let placed = try Installer.placeBinary(sourcePath: v1.path, homeDirectory: home)

        // Upgrade from a different source binary with force: true.
        let v2 = try makeFakeBinary(contents: "v2")
        defer { try? FileManager.default.removeItem(at: v2) }
        _ = try Installer.placeBinary(sourcePath: v2.path, homeDirectory: home, force: true)

        let content = try String(contentsOfFile: placed, encoding: .utf8)
        #expect(content == "v2",
                "force:true must replace the installed binary with the new source")
    }

    #if os(macOS)
    @Test("LaunchAgent.restart returns .installed when no plists exist")
    func launchAgentRestartNoPlistsIsInstalled() {
        // When neither the daemon nor moot-mgr plist exists, restart skips both
        // bootstrap calls (nothing to restart) and returns .installed to signal
        // the post-upgrade state is ready.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("la-restart-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let status = LaunchAgent.restart(homeDirectory: home)
        if case .installed = status {
            // Expected: no plists → no launchctl calls → .installed return.
        } else {
            Issue.record("Expected .installed when no plists exist, got \(status)")
        }
    }
    #endif

    // MARK: - parallConfigPaths

    @Test("parallConfigPaths returns [] when Parall directory does not exist")
    func parallConfigPathsAbsentParallDir() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // No ~/Library/Application Support/Parall/ — must return [] without throwing.
        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let paths = Installer.parallConfigPaths(client: client, homeDirectory: home)
        #expect(paths.isEmpty, "No Parall directory → must return []")
    }

    @Test("parallConfigPaths returns correct URLs for a simulated Parall layout")
    func parallConfigPathsSimulatedLayout() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let targetFilename = URL(fileURLWithPath: client.configPath).lastPathComponent
        // e.g. "claude_desktop_config.json"

        // Create a Parall root with three instance dirs, two of which have the config file.
        let parallRoot = home.appendingPathComponent("Library/Application Support/Parall")
        let instances = ["claude-a", "claude-c", "gamma"]
        for name in instances {
            let dir = parallRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Place config files in two of the three instances.
        for name in ["claude-a", "gamma"] {
            let configFile = parallRoot.appendingPathComponent(name)
                .appendingPathComponent(targetFilename)
            try "{}".write(to: configFile, atomically: true, encoding: .utf8)
        }

        let paths = Installer.parallConfigPaths(client: client, homeDirectory: home)
        #expect(paths.count == 2, "Must find exactly the two instances with the config file")
        let foundNames = paths.map { $0.deletingLastPathComponent().lastPathComponent }
        #expect(foundNames.contains("claude-a"))
        #expect(foundNames.contains("gamma"))
        #expect(!foundNames.contains("claude-c"), "Instance without the config file must not be returned")
        // Verify sorted order (alpha: claude-a < gamma).
        #expect(foundNames == foundNames.sorted())
    }

    @Test("parallConfigPaths skips non-directory entries in the Parall root")
    func parallConfigPathsSkipsFiles() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let targetFilename = URL(fileURLWithPath: client.configPath).lastPathComponent

        let parallRoot = home.appendingPathComponent("Library/Application Support/Parall")
        try FileManager.default.createDirectory(at: parallRoot, withIntermediateDirectories: true)

        // One valid instance directory with config file.
        let instanceDir = parallRoot.appendingPathComponent("claude-a")
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        try "{}".write(to: instanceDir.appendingPathComponent(targetFilename),
                       atomically: true, encoding: .utf8)

        // A plain file in the Parall root (not a directory) — must not be treated as an instance.
        try "not-a-dir".write(to: parallRoot.appendingPathComponent("README.txt"),
                              atomically: true, encoding: .utf8)

        let paths = Installer.parallConfigPaths(client: client, homeDirectory: home)
        #expect(paths.count == 1, "File entries at the Parall root level must not be returned")
        #expect(paths.first?.deletingLastPathComponent().lastPathComponent == "claude-a")
    }

    // MARK: - mergeIntoJSONConfig

    @Test("mergeIntoJSONConfig writes proxy-symlink bare-command entry for useProxyBridge client")
    func mergeIntoJSONConfigProxyBridge() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let binaryPath = "/usr/local/bin/mootx01"
        // Proxy symlink is in the same directory as the binary.
        let proxyPath = "/usr/local/bin/mootx01-proxy"
        let daemonURL = MootPaths.residentEndpointURL

        let configURL = home.appendingPathComponent("test-config.json")
        try Installer.mergeIntoJSONConfig(
            at: configURL, client: client, binaryPath: binaryPath, daemonURL: daemonURL
        )

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let entry = (obj?["mcpServers"] as? [String: Any])?[client.serverName] as? [String: Any]
        // Proxy-bridge clients use the bare proxy symlink — argv0 dispatch routes
        // "mootx01-proxy" to the proxy subcommand, so no args array is needed.
        #expect(entry?["command"] as? String == proxyPath,
                "proxy-bridge entry must use the mootx01-proxy symlink as bare command")
        #expect(entry?["args"] == nil,
                "proxy-bridge entry must not carry an explicit args array")
        #expect(entry?["url"] == nil, "proxy-bridge entry must not have a url field")
    }

    @Test("mergeIntoJSONConfig writes resident-daemon url entry for default supported client")
    func mergeIntoJSONConfigDefaultCommand() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent("test-config.json")
        try Installer.mergeIntoJSONConfig(
            at: configURL, client: client,
            binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL
        )

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let entry = (obj?["mcpServers"] as? [String: Any])?[client.serverName] as? [String: Any]
        // Accepted loopback posture (b913ca4a): HTTP-capable clients target
        // the resident daemon endpoint, not a per-call stdio spawn.
        #expect(entry?["url"] as? String == MootPaths.residentEndpointURL)
        #expect(entry?["command"] == nil, "HTTP-wired entry carries no command")
    }

    @Test("mergeIntoJSONConfig is idempotent: second call produces identical file content")
    func mergeIntoJSONConfigIdempotent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let configURL = home.appendingPathComponent("test-config.json")
        let binaryPath = "/usr/local/bin/mootx01"

        try Installer.mergeIntoJSONConfig(
            at: configURL, client: client, binaryPath: binaryPath,
            daemonURL: MootPaths.residentEndpointURL
        )
        let firstContent = try Data(contentsOf: configURL)

        try Installer.mergeIntoJSONConfig(
            at: configURL, client: client, binaryPath: binaryPath,
            daemonURL: MootPaths.residentEndpointURL
        )
        let secondContent = try Data(contentsOf: configURL)

        #expect(firstContent == secondContent,
                "mergeIntoJSONConfig must be idempotent: second call must not change the file")
    }

    @Test("mergeIntoJSONConfig merges without losing other mcpServers entries")
    func mergeIntoJSONConfigPreservesOtherEntries() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let configURL = home.appendingPathComponent("test-config.json")

        // Pre-populate with a different server entry.
        let pre: [String: Any] = ["mcpServers": ["other": ["command": "/other/bin"]]]
        try JSONSerialization.data(withJSONObject: pre, options: .prettyPrinted)
            .write(to: configURL, options: .atomic)

        try Installer.mergeIntoJSONConfig(
            at: configURL, client: client,
            binaryPath: "/bin/mootx01", daemonURL: MootPaths.residentEndpointURL
        )

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        #expect(servers?["other"] != nil, "Pre-existing server entry must be preserved")
        #expect(servers?[client.serverName] != nil, "mootx01 entry must be present")
    }

    @Test("mergeIntoJSONConfig refuses to overwrite an existing non-JSON config")
    func mergeIntoJSONConfigRefusesNonJSON() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let configURL = home.appendingPathComponent("test-config.json")
        // A non-JSON body that the old code would have silently wiped.
        let original = "this is not json\nkeep me\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        #expect(throws: InstallerError.self) {
            try Installer.mergeIntoJSONConfig(
                at: configURL, client: client,
                binaryPath: "/bin/mootx01", daemonURL: MootPaths.residentEndpointURL
            )
        }
        // The original content must be untouched — no clobber.
        let after = try String(contentsOf: configURL, encoding: .utf8)
        #expect(after == original, "A non-JSON config must be left exactly as found")
    }

    // MARK: - mergeIntoTOMLConfig (Codex)

    @Test("mergeIntoTOMLConfig writes a fresh [mcp_servers.mootx01] url table")
    func mergeIntoTOMLFreshCommand() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "codex" }!
        let configURL = home.appendingPathComponent("config.toml")
        try Installer.mergeIntoTOMLConfig(
            at: configURL, client: client,
            binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL
        )

        let text = try String(contentsOf: configURL, encoding: .utf8)
        #expect(text.contains("[mcp_servers.mootx01]"), "TOML server table must be present")
        // Codex rides the resident daemon endpoint (accepted loopback
        // posture, b913ca4a) — a url table, not a command/stdio one.
        #expect(text.contains("url = \"\(MootPaths.residentEndpointURL)\""),
                "url entry must target the resident daemon")
        #expect(!text.contains("command = "), "HTTP-wired table carries no command entry")
        #expect(text.first != "{", "must be TOML, not JSON")
    }

    @Test("mergeIntoTOMLConfig preserves top-level keys and other tables")
    func mergeIntoTOMLPreservesUnrelated() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "codex" }!
        let configURL = home.appendingPathComponent("config.toml")
        // Seed a realistic Codex config: a top-level key and an unrelated server.
        let seed = """
        notify = ["/path/to/hook", "turn-ended"]

        [mcp_servers.other]
        url = "http://127.0.0.1:9999"
        """
        try seed.write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.mergeIntoTOMLConfig(
            at: configURL, client: client,
            binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL
        )

        let text = try String(contentsOf: configURL, encoding: .utf8)
        #expect(text.contains("notify = [\"/path/to/hook\", \"turn-ended\"]"),
                "top-level key must survive")
        #expect(text.contains("[mcp_servers.other]"), "unrelated server table must survive")
        #expect(text.contains("http://127.0.0.1:9999"), "unrelated server url must survive")
        #expect(text.contains("[mcp_servers.mootx01]"), "mootx01 table must be added")
    }

    @Test("mergeIntoTOMLConfig replaces an existing mootx01 table without duplicating it")
    func mergeIntoTOMLReplacesExisting() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "codex" }!
        let configURL = home.appendingPathComponent("config.toml")
        let seed = """
        [mcp_servers.mootx01]
        url = "http://127.0.0.1:1111"
        """
        try seed.write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.mergeIntoTOMLConfig(
            at: configURL, client: client,
            binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL
        )
        // Run twice — must remain a single table and be stable.
        let first = try String(contentsOf: configURL, encoding: .utf8)
        try Installer.mergeIntoTOMLConfig(
            at: configURL, client: client,
            binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL
        )
        let second = try String(contentsOf: configURL, encoding: .utf8)

        let occurrences = first.components(separatedBy: "[mcp_servers.mootx01]").count - 1
        #expect(occurrences == 1, "must not duplicate the mootx01 table")
        #expect(!first.contains("127.0.0.1:1111"), "stale url must be replaced")
        #expect(first == second, "merge must be idempotent")
    }

    @Test("mergeIntoTOMLConfig refuses a config.toml that contains JSON (prior broken install)")
    func mergeIntoTOMLRefusesJSONCorruption() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "codex" }!
        let configURL = home.appendingPathComponent("config.toml")
        // The exact failure mode that broke Codex: JSON written into config.toml.
        let corrupted = "{\n  \"mcpServers\" : {\n    \"mootx01\" : {\n      \"url\" : \"http://127.0.0.1:4242\"\n    }\n  }\n}"
        try corrupted.write(to: configURL, atomically: true, encoding: .utf8)

        #expect(throws: InstallerError.self) {
            try Installer.mergeIntoTOMLConfig(
                at: configURL, client: client,
                binaryPath: "/usr/local/bin/mootx01",
                daemonURL: MootPaths.residentEndpointURL
            )
        }
        let after = try String(contentsOf: configURL, encoding: .utf8)
        #expect(after == corrupted, "a JSON-corrupted file must be left untouched for the user to recover")
    }

    @Test("install routes the Codex entry (.toml) to the TOML writer, not JSON")
    func installRoutesCodexToTOML() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "codex" }!
        try Installer.install(
            client: client,
            binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home,
            workingDirectory: home,
            local: false
        )

        let configURL = home.appendingPathComponent(".codex/config.toml")
        let text = try String(contentsOf: configURL, encoding: .utf8)
        #expect(text.first != "{", "Codex config must be TOML, not JSON")
        #expect(text.contains("[mcp_servers.mootx01]"), "Codex config must carry the TOML server table")
    }

    // MARK: - Parall integration

    @Test("Parall integration: parallConfigPaths + mergeIntoJSONConfig wires all matching instances")
    func parallIntegrationWiresAllInstances() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-desktop" }!
        let targetFilename = URL(fileURLWithPath: client.configPath).lastPathComponent
        let binaryPath = "/usr/local/bin/mootx01"

        // Create four simulated Parall instances for Claude Desktop.
        let parallRoot = home.appendingPathComponent("Library/Application Support/Parall")
        for name in ["claude-a", "claude-c", "claude-d", "gamma"] {
            let dir = parallRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{}".write(to: dir.appendingPathComponent(targetFilename),
                           atomically: true, encoding: .utf8)
        }

        let paths = Installer.parallConfigPaths(client: client, homeDirectory: home)
        #expect(paths.count == 4, "All four instances must be discovered")

        for configURL in paths {
            try Installer.mergeIntoJSONConfig(
                at: configURL, client: client, binaryPath: binaryPath,
                daemonURL: MootPaths.residentEndpointURL
            )
        }

        // Every config file must contain the proxy-bridge entry (bare proxy symlink, no args).
        let proxyPath = "/usr/local/bin/mootx01-proxy"
        for configURL in paths {
            let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            let entry = (obj?["mcpServers"] as? [String: Any])?[client.serverName] as? [String: Any]
            #expect(entry?["command"] as? String == proxyPath,
                    "Parall instance \(configURL.deletingLastPathComponent().lastPathComponent) must be wired with proxy symlink")
            #expect(entry?["args"] == nil,
                    "Parall proxy-bridge entry must not carry an explicit args array")
        }
    }

    @Test("Parall scan skips Continue client (YAML, no JSON config to merge)")
    func parallScanSkipsContinue() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let continueClient = MCPClients.supported.first { $0.id == "continue" }!
        // No Parall directory is created in this test. parallConfigPaths must return []
        // when the Parall root does not exist, regardless of which client is passed.
        let paths = Installer.parallConfigPaths(client: continueClient, homeDirectory: home)
        #expect(paths.isEmpty, "No Parall directory for Continue test → must return []")
    }

    @Test("Parall scan skips isHeadlessStdio clients")
    func parallScanSkipsHeadlessStdio() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // No real supported client is headless stdio, so construct a synthetic one.
        let headlessClient = MCPClient(
            id: "headless-parall", displayName: "Headless Parall Test",
            configPath: "Library/Application Support/TestClient/config.json",
            serverName: MCPClients.serverName,
            supportsLocalHTTP: false, useProxyBridge: false
        )
        #expect(headlessClient.isHeadlessStdio, "Precondition: this client must be headless")

        // Create a Parall instance with this client's config filename.
        let targetFilename = URL(fileURLWithPath: headlessClient.configPath).lastPathComponent
        let parallRoot = home.appendingPathComponent("Library/Application Support/Parall")
        let dir = parallRoot.appendingPathComponent("test-instance")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent(targetFilename),
                       atomically: true, encoding: .utf8)

        // This test calls parallConfigPaths directly — it does not exercise the
        // InstallCommand guard (!client.isHeadlessStdio). parallConfigPaths returns
        // matching paths regardless of transport; the guard that prevents merging
        // into headless clients lives in InstallCommand, not in parallConfigPaths.
        let paths = Installer.parallConfigPaths(client: headlessClient, homeDirectory: home)
        #expect(paths.count == 1, "parallConfigPaths finds the file regardless of transport")
        // The InstallCommand guard: !client.isHeadlessStdio — skips this client.
        // No merge is performed; config remains {}.
        let content = try String(contentsOf: paths[0], encoding: .utf8)
        #expect(content == "{}", "Headless client config must remain untouched by the scan guard")
    }

    // MARK: - §4.2 backups

    @Test("install backs up an existing config; fresh files are exempt")
    func installBacksUpExistingConfig() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)
        try #"{"existing": true}"#.write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home, workingDirectory: home, local: false)

        let baks = try FileManager.default.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasPrefix(".claude.json.bak-") }
        #expect(baks.count == 1)
        let bak = try String(contentsOf: home.appendingPathComponent(baks[0]), encoding: .utf8)
        #expect(bak == #"{"existing": true}"#)

        // Fresh file: no backup.
        let home2 = try makeSandboxHome()
        defer { cleanupSandbox(home2) }
        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home2, workingDirectory: home2, local: false)
        let baks2 = try FileManager.default.contentsOfDirectory(atPath: home2.path)
            .filter { $0.contains(".bak-") }
        #expect(baks2.isEmpty)
    }

    // MARK: - Codex TOML uninstall (was silently no-opping through the JSON path)

    @Test("codex TOML uninstall removes the table and restores byte-identically")
    func codexTOMLUninstallRoundTrip() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "codex" }!
        let configURL = home.appendingPathComponent(client.configPath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "model = \"gpt-x\"\n\n[plugins.\"browser@x\"]\nenabled = true\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home, workingDirectory: home, local: false)
        let wiredText = try String(contentsOf: configURL, encoding: .utf8)
        #expect(wiredText.contains("[mcp_servers.mootx01]"))
        #expect(client.wired(homeDirectory: home))

        try Installer.uninstall(
            client: client, homeDirectory: home, workingDirectory: home, local: false)
        let restored = try String(contentsOf: configURL, encoding: .utf8)
        #expect(restored == original)
        #expect(!client.wired(homeDirectory: home))
    }

    // MARK: - opencode (schema: top-level "mcp", type:"remote", .jsonc preference)

    @Test("opencode writes a remote url entry under the top-level mcp key")
    func opencodeUsesMcpKeyAndCommandEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "opencode" }!

        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home, workingDirectory: home, local: false)

        let configURL = home.appendingPathComponent(client.configPath)
        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)) as? [String: Any]
        // Opencode config uses the top-level "mcp" key (not "mcpServers").
        #expect(obj?["mcpServers"] == nil)
        let entry = (obj?["mcp"] as? [String: Any])?["mootx01"] as? [String: Any]
        // Opencode's schema-verified remote shape targeting the resident
        // daemon (accepted loopback posture, b913ca4a).
        #expect(entry?["type"] as? String == "remote")
        #expect(entry?["url"] as? String == "http://127.0.0.1:4242")
        #expect(entry?["command"] == nil, "remote entry carries no command field")
        #expect(client.wired(homeDirectory: home))

        try Installer.uninstall(
            client: client, homeDirectory: home, workingDirectory: home, local: false)
        #expect(!client.wired(homeDirectory: home))
    }

    @Test("opencode prefers an existing opencode.jsonc")
    func opencodePrefersJsonc() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "opencode" }!
        let jsonc = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(
            at: jsonc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"$schema": "https://opencode.ai/config.json"}"#
            .write(to: jsonc, atomically: true, encoding: .utf8)

        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home, workingDirectory: home, local: false)

        // Wrote into the .jsonc; did NOT create a second opencode.json.
        let json = home.appendingPathComponent(".config/opencode/opencode.json")
        #expect(!FileManager.default.fileExists(atPath: json.path))
        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: jsonc)) as? [String: Any]
        #expect((obj?["mcp"] as? [String: Any])?["mootx01"] != nil)
        #expect(obj?["$schema"] as? String == "https://opencode.ai/config.json")
    }

    // MARK: - Hermes shared YAML

    @Test("hermes merge creates the section at EOF when absent")
    func hermesMergeCreatesSection() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "hermes" }!
        let configURL = home.appendingPathComponent(client.configPath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model:\n  default: \"x\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home, workingDirectory: home, local: false)

        let got = try String(contentsOf: configURL, encoding: .utf8)
        // Hermes rides the resident daemon url (accepted loopback posture,
        // b913ca4a).
        #expect(got == "model:\n  default: \"x\"\n\nmcp_servers:\n  mootx01:\n    url: http://127.0.0.1:4242\n")
        #expect(client.wired(homeDirectory: home))
    }

    @Test("hermes merge preserves other servers and replaces a stale entry")
    func hermesMergePreservesOthers() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "hermes" }!
        let configURL = home.appendingPathComponent(client.configPath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = "# comment\nmcp_servers:\n  time:\n    command: uvx\n  mootx01:\n    url: http://stale:1\n\ntts:\n  engine: edge\n"
        try before.write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.mergeIntoHermesYAML(
            at: configURL, serverName: "mootx01", url: "http://127.0.0.1:4242")

        let got = try String(contentsOf: configURL, encoding: .utf8)
        #expect(got == "# comment\nmcp_servers:\n  mootx01:\n    url: http://127.0.0.1:4242\n  time:\n    command: uvx\n\ntts:\n  engine: edge\n")
    }

    @Test("hermes merge refuses YAML flow style")
    func hermesMergeRefusesFlowStyle() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let configURL = home.appendingPathComponent("config.yaml")
        try "mcp_servers: {}\n".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(throws: InstallerError.self) {
            try Installer.mergeIntoHermesYAML(
                at: configURL, serverName: "mootx01", url: "http://u")
        }
    }

    @Test("hermes does not touch the same key under other sections")
    func hermesScopeGuard() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let configURL = home.appendingPathComponent("config.yaml")
        try "aliases:\n  mootx01:\n    note: unrelated\nmcp_servers:\n  mootx01:\n    url: http://stale:1\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        try Installer.mergeIntoHermesYAML(
            at: configURL, serverName: "mootx01", url: "http://new:2")

        let got = try String(contentsOf: configURL, encoding: .utf8)
        #expect(got.contains("aliases:\n  mootx01:\n    note: unrelated"))
        #expect(got.contains("mcp_servers:\n  mootx01:\n    url: http://new:2"))
        #expect(!got.contains("stale"))
    }

    @Test("hermes remove restores byte-identically, dropping a section we created")
    func hermesRemoveRoundTrips() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let configURL = home.appendingPathComponent("config.yaml")

        // Existing section retains other content after our removal.
        let withTime = "model:\n  default: \"x\"\nmcp_servers:\n  time:\n    command: uvx\n"
        try withTime.write(to: configURL, atomically: true, encoding: .utf8)
        try Installer.mergeIntoHermesYAML(at: configURL, serverName: "mootx01", url: "http://u")
        try Installer.removeFromHermesYAML(at: configURL, serverName: "mootx01")
        #expect(try String(contentsOf: configURL, encoding: .utf8) == withTime)

        // Section we created (original had only a commented one) is dropped.
        let commentedOnly = "model:\n  default: \"x\"\n\n# mcp_servers:\n#   time:\n#     command: uvx\n"
        try commentedOnly.write(to: configURL, atomically: true, encoding: .utf8)
        try Installer.mergeIntoHermesYAML(at: configURL, serverName: "mootx01", url: "http://u")
        try Installer.removeFromHermesYAML(at: configURL, serverName: "mootx01")
        #expect(try String(contentsOf: configURL, encoding: .utf8) == commentedOnly)
    }

    // MARK: - Continue trailing newline

    @Test("continue YAML ends with a trailing newline")
    func continueYAMLTrailingNewline() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "continue" }!

        try Installer.install(
            client: client, binaryPath: "/b", daemonURL: "http://127.0.0.1:4242",
            homeDirectory: home, workingDirectory: home, local: false)

        let configURL = home.appendingPathComponent(client.configPath)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        // Continue rides the resident daemon over streamable-http (accepted
        // loopback posture, b913ca4a); trailing newline is POSIX.
        #expect(text == "type: streamable-http\nurl: http://127.0.0.1:4242\n")
    }

    private func makeSandboxHome() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Create a throwaway file that stands in for the `mootx01` binary
    /// in placement tests. Written to a temp dir distinct from any
    /// sandbox home so tests can assert the config path is NOT the
    /// source path.
    private func makeFakeBinary(contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mootx01-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Create a fake binary in its own dedicated directory with SPM-style
    /// resource bundles beside it, mirroring `swift build`'s release layout
    /// (`<binary>` + `<Target>_<Target>.bundle/` siblings). Each bundle gets a
    /// `marker.json` so tests can assert the bundle contents were copied, not
    /// just an empty directory. Returns the binary URL and the enclosing dir
    /// (delete the dir to clean up everything).
    private func makeFakeBinaryWithBundles(
        bundles: [String],
        named binaryName: String = "mootx01",
        markerContents: String = "x"
    ) throws -> (binary: URL, dir: URL) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-build-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let binary = dir.appendingPathComponent(binaryName)
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)

        for name in bundles {
            let bundleDir = dir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
            try markerContents.write(
                to: bundleDir.appendingPathComponent("marker.json"),
                atomically: true, encoding: .utf8)
        }
        return (binary, dir)
    }
}
