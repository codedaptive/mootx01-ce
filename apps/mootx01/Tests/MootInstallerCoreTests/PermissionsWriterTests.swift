// PermissionsWriterTests.swift
//
// Tests for PermissionsWriter: tier classification (exhaustive over the real
// tool inventory), tiered merge (both namespace prefixes), allow-all merge,
// idempotency, user-placement precedence, migration of stale-tiered entries
// (deny sacred, foreign entries untouched), and prefix-based removal (both
// namespaces). Tool names are injected (the real caller derives them from
// the linked AriaMCP ToolProjection at runtime); most tests use a fixed
// fixture list, but `classificationTableIsExhaustive` uses a PINNED copy of
// the real 66-tool inventory (see its own doc comment for why it is pinned
// rather than fetched live). All I/O uses sandbox directories.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("PermissionsWriter")
struct PermissionsWriterTests {

    /// Fixture surface exercising all three tiers under the current
    /// (post re-tier) classification.
    private let toolNames = [
        "moot_estate_ping",      // allow (read/diagnostic)
        "moot_estate_status",    // allow (read/diagnostic)
        "moot_list_lenses",      // allow (read/pure listing)
        "moot_memory_search",    // allow (read)
        "moot_file_memory",      // allow (additive-unconfirmed write)
        "moot_withdraw_memory",  // ask (mutation of existing state)
        "moot_erase_memory",     // deny (destructive)
    ]

    // MARK: - Classification

    @Test("classify: reads and additive writes allow, mutations ask, destructive deny")
    func classifyTiers() {
        // Reads (diagnostics, listings, search/recall, lenses, journal read).
        #expect(PermissionsWriter.classify("moot_estate_ping") == .allow)
        #expect(PermissionsWriter.classify("moot_estate_status") == .allow)
        #expect(PermissionsWriter.classify("moot_drain_status") == .allow)
        #expect(PermissionsWriter.classify("moot_list_lenses") == .allow)
        #expect(PermissionsWriter.classify("moot_list_recipes") == .allow)
        #expect(PermissionsWriter.classify("moot_vault_status") == .allow)
        #expect(PermissionsWriter.classify("moot_vault_job") == .allow)
        #expect(PermissionsWriter.classify("moot_memory_search") == .allow, "a search is a read — must not ask")
        #expect(PermissionsWriter.classify("moot_memory_get") == .allow, "fetch-by-id is a read — must not ask")
        #expect(PermissionsWriter.classify("moot_recall_precise") == .allow)
        #expect(PermissionsWriter.classify("moot_recall_shaped") == .allow)
        #expect(PermissionsWriter.classify("moot_recall_distilled") == .allow)
        #expect(PermissionsWriter.classify("moot_fact_search") == .allow)
        #expect(PermissionsWriter.classify("moot_fact_timeline") == .allow)
        #expect(PermissionsWriter.classify("moot_connection_search") == .allow)
        #expect(PermissionsWriter.classify("moot_connection_map") == .allow)
        #expect(PermissionsWriter.classify("moot_estate_map") == .allow)
        #expect(PermissionsWriter.classify("moot_read_journal") == .allow)
        #expect(PermissionsWriter.classify("moot_federated_search") == .allow)
        #expect(PermissionsWriter.classify("moot_lens_keystones") == .allow, "every lens is a read")
        #expect(PermissionsWriter.classify("moot_lens_apriori") == .allow)

        // Additive-unconfirmed writes: create new content, alter nothing existing.
        #expect(PermissionsWriter.classify("moot_file_memory") == .allow)
        #expect(PermissionsWriter.classify("moot_file_fact") == .allow)
        #expect(PermissionsWriter.classify("moot_write_journal") == .allow)
        #expect(PermissionsWriter.classify("moot_link_memories") == .allow)

        // Mutations of existing state.
        #expect(PermissionsWriter.classify("moot_update_memory") == .ask)
        #expect(PermissionsWriter.classify("moot_move_memory") == .ask)
        #expect(PermissionsWriter.classify("moot_withdraw_memory") == .ask, "withdraw is reversible — ask, not deny")
        #expect(PermissionsWriter.classify("moot_confirm_memory") == .ask)
        #expect(PermissionsWriter.classify("moot_retire_fact") == .ask)
        #expect(PermissionsWriter.classify("moot_confirm_migration") == .ask)
        #expect(PermissionsWriter.classify("moot_run_migration") == .ask)
        #expect(PermissionsWriter.classify("moot_reindex") == .ask)
        #expect(PermissionsWriter.classify("moot_reclassify_fdc") == .ask)
        #expect(PermissionsWriter.classify("moot_dream") == .ask)
        #expect(PermissionsWriter.classify("moot_distill") == .ask)
        // moot_consolidate is the SPEC §3 dispatch alias — same class.
        #expect(PermissionsWriter.classify("moot_consolidate") == .ask)
        #expect(PermissionsWriter.classify("moot_synthesize") == .ask)
        #expect(PermissionsWriter.classify("moot_palace_import") == .ask)
        #expect(PermissionsWriter.classify("moot_vault_import") == .ask)
        #expect(PermissionsWriter.classify("moot_vault_export") == .ask)
        #expect(PermissionsWriter.classify("moot_vault_reconcile") == .ask)
        // monitoring_status mutates daemon behaviour when `enabled` is supplied.
        #expect(PermissionsWriter.classify("moot_monitoring_status") == .ask, "monitoring_status is mutating — ask tier")

        // Destructive.
        #expect(PermissionsWriter.classify("moot_erase_memory") == .deny)

        // A brand-new, not-yet-triaged tool must land in the safe middle.
        #expect(PermissionsWriter.classify("moot_future_tool") == .ask)
    }

    /// Priority coverage for the re-tier ruling: the tier table must be
    /// EXHAUSTIVE over the real tool inventory, so a future tool addition
    /// fails this test instead of silently landing in `ask` unnoticed —
    /// the same failure mode `--grant-permissions` already suffered once
    /// from a hardcoded name list going stale.
    ///
    /// This uses a PINNED copy of the real tool inventory rather than
    /// fetching it live from `AriaMCP.ToolProjection.tools()`: MootInstallerCore
    /// (and its test target) deliberately does NOT depend on AriaMcpKit —
    /// AriaMcpKit requires macOS(.v26) (see Package.swift's platform
    /// comment), and MootInstallerCoreTests is built cross-platform
    /// (Linux too, per the same comment). Making the live tool-list seam
    /// reachable here would force every Linux test run to build the
    /// macOS-only AriaMCP/GeniusLocusKit/PersistenceKitSQLite dependency
    /// chain — out of scope for this mission. The count guard below is the
    /// safety net for THIS pinned copy going stale: if the real surface
    /// grows or shrinks, the count assertion fails loudly even before the
    /// per-name comparison would, naming exactly how far off it is.
    ///
    /// When AriaMcpKit's `tool_list::build_tool_list()` / `ToolProjection.tools()`
    /// gains or removes a tool, update BOTH this pinned list and whichever
    /// of `readTools` / `additiveWriteTools` / `mutationTools` /
    /// `destructiveTools` the new tool belongs in.
    @Test("classify's tier tables are exhaustive over the real 71-tool inventory")
    func classificationTableIsExhaustive() {
        let realTools: Set<String> = [
            "moot_confirm_memory", "moot_confirm_migration", "moot_connection_map",
            "moot_connection_search", "moot_consolidate", "moot_distill", "moot_drain_status", "moot_dream",
            "moot_dataset_query", "moot_dataset_stats", "moot_file_dataset",
            "moot_erase_memory", "moot_estate_map", "moot_estate_ping", "moot_estate_status",
            "moot_fact_search", "moot_fact_timeline", "moot_federated_search", "moot_file_fact",
            "moot_file_memory", "moot_hunt_contradictions",
            "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations",
            "moot_lens_bias", "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts",
            "moot_lens_constellation", "moot_lens_contradiction", "moot_lens_divergence",
            "moot_lens_drift", "moot_lens_free_association", "moot_lens_keystones",
            "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion",
            "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm",
            "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis",
            "moot_link_memories", "moot_list_lenses", "moot_list_recipes", "moot_memory_get",
            "moot_memory_list", "moot_memory_search", "moot_monitoring_status", "moot_move_memory",
            "moot_palace_import",
            "moot_read_journal", "moot_recall_distilled", "moot_recall_precise", "moot_recall_shaped",
            "moot_reclassify_fdc", "moot_reindex", "moot_retire_fact",
            "moot_review_tunnel", "moot_run_migration",
            "moot_synthesize", "moot_update_memory", "moot_vault_export", "moot_vault_import",
            "moot_vault_job", "moot_vault_reconcile", "moot_vault_status", "moot_withdraw_memory",
            "moot_write_journal",
        ]
        // Count guard (see doc comment): 71 = 68 (contradiction hunter era) +
        // 3 dataset tools (MX-TAB-7: moot_file_dataset, moot_dataset_query,
        // moot_dataset_stats).
        // A mismatch here means THIS PINNED LIST is stale relative to
        // tool_list.rs / ToolProjection.swift — fix the pin first, then re-run
        // before trusting the set-difference below.
        #expect(realTools.count == 71, "pinned tool inventory drifted from the real surface count")

        let classified = PermissionsWriter.explicitlyClassifiedTools
        let untriaged = realTools.subtracting(classified)
        #expect(untriaged.isEmpty, "real tool(s) with no explicit tier classification: \(untriaged.sorted())")

        let stale = classified.subtracting(realTools)
        #expect(stale.isEmpty, "classification table names tool(s) no longer in the real surface: \(stale.sorted())")
    }

    @Test("permissionEntries all carry the mcp__mootx01__ prefix")
    func permissionEntryPrefix() {
        for entry in PermissionsWriter.permissionEntries(toolNames: toolNames) {
            #expect(entry.hasPrefix("mcp__mootx01__"))
        }
    }

    // MARK: - mergeTiered (the install default) — both namespaces

    @Test("mergeTiered writes each tool into its tier, under BOTH namespace prefixes")
    func mergeTieredWritesTiers() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        let added = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        // 5 allow + 1 ask + 1 deny tools, x2 for the two namespace prefixes.
        #expect(added.allow == 10 && added.ask == 2 && added.deny == 2)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        #expect(allow.contains("mcp__mootx01__moot_estate_ping"))
        #expect(allow.contains("mcp__plugin_mootx01_mootx01__moot_estate_ping"))
        #expect(ask.contains("mcp__mootx01__moot_withdraw_memory"))
        #expect(ask.contains("mcp__plugin_mootx01_mootx01__moot_withdraw_memory"))
        #expect(deny.contains("mcp__mootx01__moot_erase_memory"))
        #expect(deny.contains("mcp__plugin_mootx01_mootx01__moot_erase_memory"))
    }

    @Test("mergeTiered is idempotent")
    func mergeTieredIdempotent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        let second = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        #expect(second.allow == 0 && second.ask == 0 && second.deny == 0)

        let perms = try readPermissions(settingsURL)
        #expect((perms["allow"] as? [String])?.count == 10)
        #expect((perms["ask"] as? [String])?.count == 2)
        #expect((perms["deny"] as? [String])?.count == 2)
    }

    @Test("mergeTiered respects the user's existing placement over our default, per namespace")
    func mergeTieredRespectsUserPlacement() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // The user already allowed a tool we default to ask, and already
        // allowed one we default to deny — but ONLY under the direct
        // namespace. Their placement must survive for that exact entry;
        // the plugin-namespace twin is genuinely absent, so it gets
        // backfilled at the tool's CURRENT default (documented behavior —
        // see mergeTiered's doc comment on cross-namespace independence).
        let existing: [String: Any] = [
            "permissions": ["allow": [
                "mcp__mootx01__moot_withdraw_memory",
                "mcp__mootx01__moot_erase_memory",
            ]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        #expect(allow.contains("mcp__mootx01__moot_withdraw_memory"), "user's direct-namespace allow must survive")
        #expect(allow.contains("mcp__mootx01__moot_erase_memory"), "user's direct-namespace allow must survive even for deny-default tools")
        #expect(!ask.contains("mcp__mootx01__moot_withdraw_memory"), "must not duplicate the direct entry into ask")
        #expect(!deny.contains("mcp__mootx01__moot_erase_memory"), "must not duplicate the direct entry into deny")
        // The plugin-namespace twin was absent — backfilled at the default.
        #expect(ask.contains("mcp__plugin_mootx01_mootx01__moot_withdraw_memory"), "missing plugin-namespace twin must be backfilled at the default tier")
        #expect(deny.contains("mcp__plugin_mootx01_mootx01__moot_erase_memory"), "missing plugin-namespace twin must be backfilled at the default tier")
    }

    // MARK: - migrateTiers (existing installs converging on a new default)

    @Test("migrateTiers converges an old all-ask-tiered fixture onto the current default")
    func migrateTiersConvergesOldTiering() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // Simulate the PRE re-tier default: every non-diagnostic tool
        // landed in ask, including pure reads (moot_memory_search,
        // moot_file_memory) that now belong in allow.
        let old: [String: Any] = [
            "permissions": [
                "allow": ["mcp__mootx01__moot_estate_ping", "mcp__plugin_mootx01_mootx01__moot_estate_ping"],
                "ask": [
                    "mcp__mootx01__moot_memory_search", "mcp__plugin_mootx01_mootx01__moot_memory_search",
                    "mcp__mootx01__moot_file_memory", "mcp__plugin_mootx01_mootx01__moot_file_memory",
                    "mcp__mootx01__moot_withdraw_memory", "mcp__plugin_mootx01_mootx01__moot_withdraw_memory",
                ],
                "deny": ["mcp__mootx01__moot_erase_memory", "mcp__plugin_mootx01_mootx01__moot_erase_memory"],
            ]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: old).write(to: settingsURL)

        let moved = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
        // moot_memory_search and moot_file_memory move ask -> allow, both namespaces = 4.
        #expect(moved == 4, "expected 4 entries moved (2 tools x 2 namespaces); got \(moved)")

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        #expect(allow.contains("mcp__mootx01__moot_memory_search"))
        #expect(allow.contains("mcp__plugin_mootx01_mootx01__moot_memory_search"))
        #expect(allow.contains("mcp__mootx01__moot_file_memory"))
        #expect(allow.contains("mcp__plugin_mootx01_mootx01__moot_file_memory"))
        // The genuine mutation and the destructive tool are untouched.
        #expect(ask.contains("mcp__mootx01__moot_withdraw_memory"), "a genuine mutation must stay in ask")
        #expect(deny.contains("mcp__mootx01__moot_erase_memory"), "deny must be unaffected when it already matches the default")
        // No duplicates left behind in the old tier.
        #expect(!ask.contains("mcp__mootx01__moot_memory_search"))
        #expect(!ask.contains("mcp__mootx01__moot_file_memory"))

        // Idempotent: running again moves nothing further.
        let second = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
        #expect(second == 0)
    }

    @Test("migrateTiers never loosens a user-set ask on a mutation or destructive tool")
    func migrateTiersPreservesMutationAsk() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // Every mutation-class tool sits at ask (its shipped tier) and one
        // destructive tool was user-moved from deny to ask. Convergence must
        // not loosen ANY of them toward allow: mutation tools converge onto
        // ask (no-op) and the destructive tool converges onto deny — a
        // tightening, never a loosening. This pins the Rule 2 invariant that
        // ask→allow movement exists ONLY for allow-class (read/additive)
        // fossils.
        let existing: [String: Any] = [
            "permissions": [
                "ask": [
                    "mcp__mootx01__moot_withdraw_memory",
                    "mcp__mootx01__moot_reclassify_fdc",
                    "mcp__mootx01__moot_erase_memory",
                ]
            ]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        #expect(!allow.contains("mcp__mootx01__moot_withdraw_memory"), "mutation ask must never loosen to allow")
        #expect(!allow.contains("mcp__mootx01__moot_reclassify_fdc"), "mutation ask must never loosen to allow")
        #expect(!allow.contains("mcp__mootx01__moot_erase_memory"), "destructive ask must never loosen to allow")
        #expect(ask.contains("mcp__mootx01__moot_withdraw_memory"))
        #expect(ask.contains("mcp__mootx01__moot_reclassify_fdc"))
    }

    @Test("migrateTiers never moves an entry the user placed in deny (deny is sacred)")
    func migrateTiersPreservesUserDeny() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // The user explicitly denied a tool that defaults to allow (a read)
        // — an unusual but legitimate restriction. Migration must NOT
        // "helpfully" move it back to allow.
        let existing: [String: Any] = [
            "permissions": ["deny": ["mcp__mootx01__moot_memory_search"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        let moved = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
        #expect(moved == 0, "an entry already in deny must never be migrated")

        let perms = try readPermissions(settingsURL)
        let deny = perms["deny"] as? [String] ?? []
        #expect(deny.contains("mcp__mootx01__moot_memory_search"), "user's explicit deny must survive migration untouched")
    }

    @Test("migrateTiers never touches a foreign (non-moot) entry")
    func migrateTiersLeavesForeignEntriesAlone() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let existing: [String: Any] = [
            "permissions": [
                "allow": ["Bash(ls:*)", "mcp__other_server__some_tool"],
                "ask": ["mcp__mootx01__moot_memory_search"], // ours, stale tier — SHOULD move
            ]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        let moved = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
        #expect(moved == 1, "only our own stale-tiered entry moves")

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        #expect(allow.contains("Bash(ls:*)"), "a non-MCP Claude Code permission must be untouched")
        #expect(allow.contains("mcp__other_server__some_tool"), "a different MCP server's rule must be untouched")
        #expect(allow.contains("mcp__mootx01__moot_memory_search"), "our own stale entry must have moved to allow")
    }

    @Test("migrateTiers does not create entries that were never present, and never writes when nothing moves")
    func migrateTiersDoesNotCreateMissingEntries() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        // No settings.json exists yet — no entries of ours exist at all.
        let moved = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
        #expect(moved == 0)
        // Nothing to migrate means nothing to write — the file must not
        // spring into existence as a side effect of a no-op migration.
        #expect(!FileManager.default.fileExists(atPath: settingsURL.path),
                "migrateTiers must not create settings.json when there is nothing to move")
    }

    // MARK: - hasAnyMootEntries

    @Test("hasAnyMootEntries is false for an absent file, empty file, or foreign-only file")
    func hasAnyMootEntriesFalseCases() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        #expect(!PermissionsWriter.hasAnyMootEntries(at: dir.appendingPathComponent("nonexistent.json")))

        let foreignURL = dir.appendingPathComponent("foreign.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": ["Bash(ls:*)"]]])
            .write(to: foreignURL)
        #expect(!PermissionsWriter.hasAnyMootEntries(at: foreignURL))
    }

    @Test("hasAnyMootEntries is true once any tier carries either namespace prefix")
    func hasAnyMootEntriesTrueCases() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let directURL = dir.appendingPathComponent("direct.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["ask": ["mcp__mootx01__moot_memory_search"]]])
            .write(to: directURL)
        #expect(PermissionsWriter.hasAnyMootEntries(at: directURL))

        let pluginURL = dir.appendingPathComponent("plugin.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["deny": ["mcp__plugin_mootx01_mootx01__moot_erase_memory"]]])
            .write(to: pluginURL)
        #expect(PermissionsWriter.hasAnyMootEntries(at: pluginURL))
    }

    // MARK: - merge (allow-all opt-in) — both namespaces

    @Test("merge creates settings.json and allows every tool, under both namespace prefixes")
    func mergeCreatesFile() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        #expect(allow.count == toolNames.count * 2)
        for tool in toolNames {
            #expect(allow.contains("mcp__mootx01__\(tool)"))
            #expect(allow.contains("mcp__plugin_mootx01_mootx01__\(tool)"))
        }
    }

    @Test("merge is idempotent and preserves existing + other keys")
    func mergeIdempotentPreserving() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let existing: [String: Any] = [
            "theme": "dark",
            "permissions": ["allow": ["mcp__other__tool"]],
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)
        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["theme"] as? String == "dark")
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "existing entry must be preserved")
        #expect(allow.count == toolNames.count * 2 + 1)
    }

    @Test("merge tolerates a leading UTF-8 BOM and preserves existing settings")
    func mergeToleratesUTF8BOM() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // A settings.json written by Windows PowerShell 5.1's
        // `Set-Content -Encoding UTF8` carries a UTF-8 BOM. JSONSerialization
        // rejects it; without BOM stripping the merge would parse to an empty
        // object and silently overwrite the user's existing settings.
        let settingsURL = dir.appendingPathComponent("settings.json")
        let body: [String: Any] = ["theme": "dark", "permissions": ["allow": ["mcp__other__tool"]]]
        var bytes = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        bytes.append(try JSONSerialization.data(withJSONObject: body, options: []))
        try bytes.write(to: settingsURL)

        try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)

        let updated = try Data(contentsOf: settingsURL)
        #expect(Array(updated.prefix(3)) != [0xEF, 0xBB, 0xBF], "BOM should be gone after rewrite")
        let obj = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        #expect(obj?["theme"] as? String == "dark", "existing top-level keys must survive")
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "existing allow entry must survive")
    }

    // MARK: - remove — both namespaces

    @Test("remove strips both namespace prefixes' entries from all three tiers")
    func removeStripsAllTiers() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        try PermissionsWriter.remove(from: settingsURL)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any] ?? [:]
        for key in ["allow", "ask", "deny"] {
            let list = perms[key] as? [String] ?? []
            #expect(!list.contains { $0.hasPrefix("mcp__mootx01__") }, "\(key) must hold no direct-namespace entries")
            #expect(!list.contains { $0.hasPrefix("mcp__plugin_mootx01_mootx01__") }, "\(key) must hold no plugin-namespace entries")
        }
    }

    @Test("remove is prefix-based: cleans renamed/stale tools too, in both namespaces")
    func removeCleansStaleNames() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // A tool name granted by an OLD version (renamed since) must still be
        // removed — removal keys on the prefix, not a name list. Covers both
        // namespaces.
        let existing: [String: Any] = [
            "permissions": ["allow": [
                "mcp__mootx01__moot_capture_drawer",
                "mcp__plugin_mootx01_mootx01__moot_capture_drawer",
                "mcp__other__tool",
            ]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        try PermissionsWriter.remove(from: settingsURL)

        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let allow = (obj?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__other__tool"), "non-ARIA entry must be preserved")
        #expect(!allow.contains("mcp__mootx01__moot_capture_drawer"), "stale direct-namespace entry must be removed")
        #expect(!allow.contains("mcp__plugin_mootx01_mootx01__moot_capture_drawer"), "stale plugin-namespace entry must be removed")
    }

    @Test("remove is a no-op when settings.json does not exist")
    func removeNoOpWhenAbsent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("nonexistent.json")
        // Should not throw.
        try PermissionsWriter.remove(from: settingsURL)
    }

    // MARK: - Helpers

    private func readPermissions(_ settingsURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["permissions"] as? [String: Any] ?? [:]
    }

    private func makeSandboxDir() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("permwriter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
