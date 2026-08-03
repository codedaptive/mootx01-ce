// PluginPackageShapeTests.swift
//
// The plugin entry's shape asserted at the GENERATION boundary — directly
// against `InstallBundle.embedded`, before any install machinery runs.
//
// Why here and not at the install boundary: when the packager renamed the
// plugin MCP server key (7f64973aa), three install-boundary tests went red
// with "type is not http" — a symptom three layers downstream of the actual
// change, describing the wrong defect (the entry was HTTP-shaped all along;
// the key it was filed under had moved). Nothing asserted the contract where
// the contract is produced. This suite is that assertion: it reads the
// embedded packages and states what a generated plugin entry must look like,
// so the next packager change that alters the shape fails here first, in the
// vocabulary of the thing that actually changed.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("PluginPackageShape")
struct PluginPackageShapeTests {

    /// The map key a package's MCP manifest files the server entry under.
    /// Hosts differ: most use `mcpServers`, VS Code / GitHub Copilot uses
    /// `servers`. Both are the same contract for our purposes.
    private static let serverMapKeys = ["mcpServers", "servers"]

    /// A generated plugin entry carries its endpoint under one of these.
    /// Most hosts use `url`; Antigravity's schema names it `serverUrl`.
    private static let urlKeys = ["url", "serverUrl"]

    /// Every JSON file in `host`'s package that declares a server map,
    /// returned as (relative path, map key, the server map).
    private static func serverMaps(forHostID id: String) -> [(rel: String, mapKey: String, servers: [String: Any])] {
        var found: [(String, String, [String: Any])] = []
        for (rel, contents) in InstallBundle.embedded.packageFiles(forHostID: id) where rel.hasSuffix(".json") {
            guard let data = contents.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            for key in serverMapKeys {
                if let servers = root[key] as? [String: Any] {
                    found.append((rel, key, servers))
                }
            }
        }
        return found
    }

    /// The contract, stated once at the boundary that produces it: every
    /// plugin-capable host's generated MCP manifest files exactly one server,
    /// under `MCPClients.pluginServerName`, and that entry is HTTP-shaped —
    /// it points at the resident daemon over HTTP and carries neither a
    /// `command` (that is the stdio proxy-bridge shape, which the transport
    /// ruling moved away from so concurrent clients share one daemon) nor an
    /// `env` (client-side env on an HTTP entry is inert — nothing reads it).
    @Test("every plugin-capable host's generated MCP entry is HTTP-shaped under the plugin server key")
    func pluginPackageEntriesAreHTTPShaped() throws {
        // Length note: this runs long on purpose and does not split. The
        // contract is "every plugin-capable host, every MCP manifest it
        // ships" — so the host loop, the per-file assertions, and the
        // closing coverage count are one indivisible statement. Extracting
        // the loop body into a per-file helper would let the count-guard
        // drift away from the assertions it certifies, which is the precise
        // failure this suite exists to prevent.
        let pluginHosts = InstallBundle.embedded.hosts.values
            .filter(\.supportsPlugin)
            .sorted { $0.id < $1.id }

        // Guard the guard: this suite is worthless if the iteration silently
        // covers nothing — which is the exact failure mode it exists to catch.
        #expect(!pluginHosts.isEmpty, "the embedded bundle must declare plugin-capable hosts")

        var checked = 0
        for host in pluginHosts {
            let maps = Self.serverMaps(forHostID: host.id)
            #expect(!maps.isEmpty,
                    "\(host.id) is plugin-capable but its package declares no MCP server map")

            for (rel, mapKey, servers) in maps {
                let where_ = "\(host.id)/\(rel) [\(mapKey)]"

                #expect(Array(servers.keys) == [MCPClients.pluginServerName],
                        """
                        \(where_): must declare exactly the plugin server key \
                        '\(MCPClients.pluginServerName)'; got \(servers.keys.sorted())
                        """)

                guard let entry = servers[MCPClients.pluginServerName] as? [String: Any] else {
                    Issue.record("\(where_): no entry under '\(MCPClients.pluginServerName)'")
                    continue
                }

                #expect(Self.urlKeys.contains(where: { entry[$0] != nil }),
                        "\(where_): an HTTP-shaped entry must carry a url; got \(entry.keys.sorted())")
                #expect(entry["command"] == nil,
                        """
                        \(where_): HTTP-shaped entries must never carry a command — \
                        that is the stdio proxy-bridge shape
                        """)
                #expect(entry["env"] == nil,
                        "\(where_): HTTP-shaped entries must never carry an env block — it is inert")

                // Hosts whose schema takes a transport discriminator must say
                // `http`; hosts whose schema has no `type` field omit it. Any
                // other value means the entry is not HTTP-shaped at all.
                if let type = entry["type"] {
                    #expect(type as? String == "http",
                            "\(where_): transport must be http; got \(type)")
                }

                checked += 1
            }
        }

        #expect(checked == pluginHosts.count,
                """
                expected exactly one MCP manifest per plugin-capable host; \
                checked \(checked) across \(pluginHosts.count) hosts
                """)
    }

    /// The constant the installer reads must be the key the packager writes.
    /// `MCPClients.pluginServerName` is a mirror of generated data; this is
    /// the test that keeps the mirror honest. It is the direct tripwire for
    /// a repeat of 7f64973aa, where the generated key moved and the
    /// installer's copy did not.
    @Test("MCPClients.pluginServerName matches the key the packager actually emits")
    func pluginServerNameMatchesGeneratedPackages() throws {
        let emitted = Set(
            InstallBundle.embedded.hosts.values
                .filter(\.supportsPlugin)
                .flatMap { Self.serverMaps(forHostID: $0.id) }
                .flatMap(\.servers.keys)
        )
        #expect(emitted == [MCPClients.pluginServerName],
                """
                the generated packages are the authority for the plugin server key; \
                MCPClients.pluginServerName is '\(MCPClients.pluginServerName)' but the \
                packages emit \(emitted.sorted())
                """)
    }

    /// The two keys are deliberately different (7f64973aa): a plugin entry is
    /// namespaced under the plugin id by the host, so it reads as
    /// `plugin:mootx01:memory`; a direct entry has no such namespace and keeps
    /// `mootx01`. Collapsing them would break the plugin-ownership hook's
    /// ability to spot a competing direct entry.
    @Test("the plugin server key and the direct-entry server key stay distinct")
    func pluginAndDirectServerKeysAreDistinct() {
        #expect(MCPClients.pluginServerName != MCPClients.serverName)
    }
}
