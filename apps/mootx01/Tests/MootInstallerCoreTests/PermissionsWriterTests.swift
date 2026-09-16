// PermissionsWriterTests.swift
//
// Tests for PermissionsWriter: tier classification (exhaustive over the real
// tool inventory), tiered merge (both namespace prefixes), allow-all merge,
// idempotency, user-placement precedence, cross-namespace tier inheritance
// (a tier placed under either prefix binds the absent twin), migration of stale-tiered entries
// (deny sacred, foreign entries untouched), and prefix-based removal (both
// namespaces). Tool names are injected (the real caller derives them from
// the linked AriaMCP ToolProjection at runtime); most tests use a fixed
// fixture list, but `classificationTableIsExhaustive` uses a PINNED copy of
// the real 82-tool inventory (see its own doc comment for why it is pinned
// rather than fetched live). All I/O uses sandbox directories.

import Testing
import Foundation
import AriaMCP
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
        #expect(PermissionsWriter.classify("moot_federated_recall") == .allow)
        #expect(PermissionsWriter.classify("moot_lens_keystones") == .allow, "every lens is a read")
        #expect(PermissionsWriter.classify("moot_lens_apriori") == .allow)
        // Migration candidate evaluation creates branches and captures corpus entries.
        #expect(PermissionsWriter.classify("moot_migration_run") == .ask)

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
        #expect(PermissionsWriter.classify("moot_migration_confirm") == .ask)
        #expect(PermissionsWriter.classify("moot_reindex") == .ask)
        #expect(PermissionsWriter.classify("moot_reclassify_fdc") == .ask)
        #expect(PermissionsWriter.classify("moot_dream") == .ask)
        // moot_synthesize reads candidates and generates text; no write (FRZ-3).
        #expect(PermissionsWriter.classify("moot_synthesize") == .allow)
        #expect(PermissionsWriter.classify("moot_palace_import") == .ask)
        #expect(PermissionsWriter.classify("moot_json_import") == .ask)
        #expect(PermissionsWriter.classify("moot_vault_import") == .ask)
        #expect(PermissionsWriter.classify("moot_vault_export") == .ask)
        #expect(PermissionsWriter.classify("moot_vault_reconcile") == .ask)
        // monitoring_status mutates daemon behaviour when `enabled` is supplied.
        #expect(PermissionsWriter.classify("moot_monitoring_status") == .allow, "inspection-only in v2 — pure read, no estate writes")

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
    /// fetching it live from `AriaMCP.ToolProjection.tools()`. The pinned
    /// copy is deliberate: the tier tables are a product contract and this
    /// test is the place a new tool is triaged by hand. The count guard
    /// below is the safety net for THIS pinned copy going stale: if the
    /// real surface grows or shrinks, the count assertion fails loudly even
    /// before the per-name comparison would, naming exactly how far off it
    /// is. (`AriaMCP.ToolMutationInventoryTests` separately checks that the
    /// mutation tables name only real tools, against the live projection.)
    ///
    /// When AriaMcpKit's `tool_list::build_tool_list()` / `ToolProjection.tools()`
    /// gains or removes a tool, update BOTH this pinned list and whichever
    /// of `readTools` (here) or `ToolMutationInventory.additiveWriteTools` /
    /// `.mutationTools` / `.destructiveTools` (AriaMcpKit) the new tool
    /// belongs in.
    @Test("classify's tier tables are exhaustive over the real 80-tool inventory")
    func classificationTableIsExhaustive() {
        let realTools: Set<String> = [
            "moot_confirm_memory", "moot_migration_confirm", "moot_connection_map",
            "moot_connection_search", "moot_drain_status", "moot_dream",
            "moot_dataset_query", "moot_dataset_stats", "moot_file_dataset",
            "moot_erase_memory", "moot_estate_map", "moot_estate_ping", "moot_estate_status",
            "moot_fact_search", "moot_fact_timeline", "moot_federated_recall", "moot_file_fact",
            "moot_file_memory", "moot_hunt_contradictions",
            // Capability discovery — always a pure read.
            "moot_help",
            "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations",
            "moot_lens_bias", "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts",
            "moot_lens_constellation", "moot_lens_contradiction", "moot_lens_divergence",
            "moot_lens_drift", "moot_lens_free_association", "moot_lens_keystones",
            "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion",
            "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm",
            "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis",
            "moot_json_import",
            "moot_link_memories", "moot_list_lenses", "moot_list_recipes", "moot_memory_get",
            "moot_memory_list", "moot_memory_search",
            // Reads session transcript; no estate writes.
            "moot_memory_recall_transcript",
            // Migration candidate evaluation mutates branch/storage state; Ask tier.
            "moot_migration_run",
            "moot_monitoring_status",
            // Write path for daemon telemetry; Ask tier.
            "moot_monitoring_set",
            "moot_move_memory",
            "moot_palace_import",
            // Proposes contradiction candidates for human review; Ask tier.
            "moot_propose_contradictions",
            "moot_read_journal", "moot_recall_connected", "moot_recall_distilled",
            "moot_recall_precise", "moot_recall_shaped", "moot_recall_temporal",
            "moot_recall_vague", "moot_recall_walk",
            // Nearest drawers by whole-record vector; Allow tier.
            "moot_recall_similar",
            "moot_reclassify_fdc", "moot_reindex", "moot_retire_fact", "moot_timing_report",
            "moot_review_tunnel",
            "moot_synthesize", "moot_update_memory", "moot_vault_export", "moot_vault_import",
            "moot_vault_job", "moot_vault_reconcile", "moot_vault_status", "moot_withdraw_memory",
            "moot_write_journal",
            // +1 (FRZ-2 follow-up): rebuild-progress diagnostic; Allow tier.
            "moot_rebuild_status",
        ]
        // Count guard (see doc comment): 71 = 68 (contradiction hunter era) +
        // 3 dataset tools (MX-TAB-7: moot_file_dataset, moot_dataset_query,
        // moot_dataset_stats) + moot_recall_vague (Wave 2 §4.4) −
        // moot_consolidate (its alias-era dispatch name left the surface in
        // SPEC_DISTILLATION_STORAGE §3 Phase 2; the name reserves for
        // multi-item consolidation).
        // A mismatch here means THIS PINNED LIST is stale relative to
        // tool_list.rs / ToolProjection.swift — fix the pin first, then re-run
        // before trusting the set-difference below.
        // +1 (MXE-JI-1): moot_json_import — seed-file JSON lane, Ask tier.
        // +1 (C3/A6 benchmark reset): moot_timing_report — audit-derived
        // timing metrics, pure read, Allow tier.
        // +3 (ADORN-STORE-02 pin repair): moot_recall_connected (1.33.0),
        // moot_recall_temporal (1.39.0), moot_recall_walk (1.47.0) — real
        // shipped recall recipes the pin had missed; all Allow-tier reads.
        // +1 (FRZ-2 follow-up): moot_rebuild_status (rebuild progress read) —
        // Allow tier; was in frozenReadTools but absent from this installer pin.
        // −4 (V2-PACKETS-RETIRE): four work-packet operations retired outright
        // (the filing tool and the three read tools).
        // −2 (Encoder Rerank Program): moot_distill and moot_redistill retired
        // (distillation is inline at read); moot_synthesize now classified as a
        // read (it was live but unclassified).
        // +1: moot_recall_similar — paraphrase recall over the whole-record lane, Allow tier.
        #expect(realTools.count == 81, "pinned tool inventory drifted from the real surface count")

        let classified = PermissionsWriter.explicitlyClassifiedTools
        let untriaged = realTools.subtracting(classified)
        #expect(untriaged.isEmpty, "real tool(s) with no explicit tier classification: \(untriaged.sorted())")

        let stale = classified.subtracting(realTools)
        #expect(stale.isEmpty, "classification table names tool(s) no longer in the real surface: \(stale.sorted())")
    }

    /// Safety-net: compare the pinned inventory against the live ToolProjection
    /// under every opt-in flag combination so future drift fails this test
    /// instead of landing silently in `ask`. The test mirrors the approach
    /// FrozenPostureTests uses to check completeness of the frozen sets.
    ///
    /// Only `moot_`-prefixed tools are checked: the `memory` tool (Anthropic
    /// adapter, opt-in via MOOTX01_MEMORY_TOOL) is not managed by the
    /// installer and therefore not in the classification tables.
    @Test("every moot_ tool reachable under any flag combination is explicitly classified")
    func classificationCoversLiveProjectionUnderAllFlags() {
        // Four combinations: MOOTX01_VAULT × MOOTX01_MEMORY_TOOL.
        let flagCombinations: [[String: String]] = {
            var combos: [[String: String]] = []
            for vault in ["1", "0"] {
                for memory in ["0", "1"] {
                    combos.append(["MOOTX01_VAULT": vault, "MOOTX01_MEMORY_TOOL": memory])
                }
            }
            return combos
        }()

        let classified = PermissionsWriter.explicitlyClassifiedTools

        for env in flagCombinations {
            let projected = ToolProjection.tools(environment: env)
                .map(\.name)
                .filter { $0.hasPrefix("moot_") }
            let unclassified = Set(projected).subtracting(classified)
            #expect(
                unclassified.isEmpty,
                "live tool(s) with no tier classification under \(env): \(unclassified.sorted())"
            )
        }
    }

    @Test("permissionEntries all carry the mcp__mootx01__ prefix")
    func permissionEntryPrefix() {
        for entry in PermissionsWriter.permissionEntries(toolNames: toolNames) {
            #expect(entry.hasPrefix("mcp__mootx01__"))
        }
    }

    @Test("retired WorkPacket tools are omitted from installer authorization inventory")
    func retiredWorkPacketToolsAreNotAuthorized() {
        let retired = ["moot_file_packet", "moot_packet_get", "moot_packet_list", "moot_packet_lineage"]
        let entries = Set(PermissionsWriter.permissionEntries(toolNames: ["moot_memory_get"] + retired))

        #expect(entries.contains("\(PermissionsWriter.mcpPrefix)moot_memory_get"))
        for tool in retired {
            #expect(!entries.contains("\(PermissionsWriter.mcpPrefix)\(tool)"))
        }
    }

    @Test("retired WorkPacket tools are omitted from the mergeTiered default install path")
    func retiredNameIsFilteredFromMergeTiered() throws {
        // mergeTiered is the default install path (InstallCommand calls it).
        // A retired name injected alongside a real name must not appear in
        // any tier under either namespace prefix, while the ordinary name
        // still lands in its classifier-assigned tier.
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        let retired = "moot_file_packet"  // retired in V2-PACKETS-RETIRE
        let ordinary = "moot_memory_get"
        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: [ordinary, retired])

        let perms = try readPermissions(settingsURL)
        let allEntries = Set(
            ((perms["allow"] as? [String]) ?? [])
            + ((perms["ask"] as? [String]) ?? [])
            + ((perms["deny"] as? [String]) ?? [])
        )

        // The ordinary name lands in its tier (allow for a read tool), under both prefixes.
        for prefix in PermissionsWriter.allPrefixes {
            #expect(allEntries.contains("\(prefix)\(ordinary)"),
                "ordinary tool \(ordinary) must appear in some tier under \(prefix)")
        }
        // The retired name must not appear under any prefix or in any tier.
        for prefix in PermissionsWriter.allPrefixes {
            #expect(!allEntries.contains("\(prefix)\(retired)"),
                "retired tool \(retired) must not appear in any tier under \(prefix)")
        }
    }

    @Test("retired WorkPacket tools are not written by the migrateTiers upgrade path")
    func retiredNameIsFilteredFromMigrateTiers() throws {
        // migrateTiers is the upgrade path (UpgradeCommand calls it).
        // A retired name present in the settings file must not be moved by
        // migration, while an ordinary name converges onto its correct tier.
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        let retired = "moot_packet_get"
        let ordinary = "moot_memory_get"

        // The retired name is seeded in `allow` rather than left absent because
        // `migrateTiers` skips any name not already present in a tier — an absent
        // entry is `mergeTiered`'s job, not migration's. Seeding the retired name in
        // `allow` makes the assertion able to fail: without the retired-name filter,
        // `classify` returns `.ask` for this untriaged name and `migrateTiers` would
        // move it from `allow` to `ask`. With the filter, the name is excluded from
        // the loop and stays in `allow`.
        let seed: [String: Any] = [
            "permissions": [
                // Ordinary name in the old all-ask default so migration has work to do.
                "ask": ["\(PermissionsWriter.mcpPrefix)\(ordinary)",
                        "\(PermissionsWriter.pluginMcpPrefix)\(ordinary)"],
                // Retired name already in allow — migration must leave it there.
                "allow": ["\(PermissionsWriter.mcpPrefix)\(retired)",
                          "\(PermissionsWriter.pluginMcpPrefix)\(retired)"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsURL)

        // Pin the premise that makes the assertions below discriminating.
        // migrateTiers classifies each name and moves it if its current tier
        // differs from classify's result. classify returns .ask for any name
        // not in readTools or additiveWriteTools (the untriaged default). If
        // this ever changed and classify returned .allow for moot_packet_get,
        // the retired name would already be at its target tier in the seed
        // and migrateTiers would leave it there — the assertions below would
        // pass with or without the retired-name filter.
        #expect(PermissionsWriter.classify(retired) == .ask,
            "moot_packet_get must return .ask from classify (untriaged default); a different return value would de-discriminate the retired-name assertions below")

        _ = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: [ordinary, retired])

        let perms = try readPermissions(settingsURL)
        let allowSet = Set((perms["allow"] as? [String]) ?? [])
        let askSet   = Set((perms["ask"]   as? [String]) ?? [])
        let denySet  = Set((perms["deny"]  as? [String]) ?? [])

        // The ordinary name must have been moved from ask to allow: it is a read tool
        // and `classify` returns `.allow` for it.
        for prefix in PermissionsWriter.allPrefixes {
            #expect(allowSet.contains("\(prefix)\(ordinary)"),
                "ordinary tool \(ordinary) must be in allow after migration under \(prefix)")
        }
        // The retired name must remain in allow and must not appear in ask or deny.
        // If the filter were removed, `migrateTiers` would classify it as `.ask`
        // (untriaged default) and move it there, failing both assertions below.
        for prefix in PermissionsWriter.allPrefixes {
            #expect(allowSet.contains("\(prefix)\(retired)"),
                "retired tool \(retired) must remain in allow (not be moved) under \(prefix)")
            #expect(!askSet.contains("\(prefix)\(retired)"),
                "retired tool \(retired) must not appear in ask under \(prefix)")
            #expect(!denySet.contains("\(prefix)\(retired)"),
                "retired tool \(retired) must not appear in deny under \(prefix)")
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
        #expect(allow.contains("mcp__plugin_mootx01_memory__moot_estate_ping"))
        #expect(ask.contains("mcp__mootx01__moot_withdraw_memory"))
        #expect(ask.contains("mcp__plugin_mootx01_memory__moot_withdraw_memory"))
        #expect(deny.contains("mcp__mootx01__moot_erase_memory"))
        #expect(deny.contains("mcp__plugin_mootx01_memory__moot_erase_memory"))
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
        // namespace. Their placement must survive for that exact entry, and
        // the absent plugin-namespace twin now INHERITS that placement
        // rather than taking the classifier default: the two prefixes are
        // two addresses for one capability, so a tier set under either binds
        // the other (see mergeTiered's doc comment).
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
        // The plugin-namespace twin was absent — it inherits the sibling's
        // tier (allow), NOT classify's default (ask / deny respectively).
        #expect(allow.contains("mcp__plugin_mootx01_memory__moot_withdraw_memory"), "absent plugin twin must inherit the sibling's allow, not classify's ask")
        #expect(!ask.contains("mcp__plugin_mootx01_memory__moot_withdraw_memory"), "absent plugin twin must not take the classifier default")
        #expect(allow.contains("mcp__plugin_mootx01_memory__moot_erase_memory"), "absent plugin twin must inherit the sibling's allow, not classify's deny")
        #expect(!deny.contains("mcp__plugin_mootx01_memory__moot_erase_memory"), "absent plugin twin must not take the classifier default")
    }

    // MARK: - mergeTiered — a placement under either namespace binds its twin
    //
    // Codex finding 2d36552ac03c8191867d26bb6ae32376: matching entries by
    // exact string and backfilling each prefix independently would let a
    // user who denies a tool under the namespace they can see get the other
    // namespace's twin added to `allow` on the next install or upgrade.
    // These pin the inheritance rule that prevents it, in both directions.

    @Test("a deny under the direct namespace binds the absent plugin twin")
    func mergeTieredDenyBindsAbsentPluginTwin() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // moot_memory_search classifies `allow` (it is a read). The user has
        // denied it under the only namespace they have ever seen. Backfilling
        // the plugin twin at the classifier default would put the SAME
        // capability in `allow` — the bypass this test exists to prevent.
        let existing: [String: Any] = [
            "permissions": ["deny": ["mcp__mootx01__moot_memory_search"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        #expect(deny.contains("mcp__mootx01__moot_memory_search"), "the user's deny must survive untouched")
        #expect(
            deny.contains("mcp__plugin_mootx01_memory__moot_memory_search"),
            "the absent plugin twin must inherit deny — a user cannot place an entry for a namespace they have never seen"
        )
        #expect(
            !allow.contains("mcp__plugin_mootx01_memory__moot_memory_search"),
            "the denied capability must not reappear in allow under the sibling namespace"
        )
    }

    @Test("an ask under the direct namespace binds the absent plugin twin")
    func mergeTieredAskBindsAbsentPluginTwin() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // Same shape as the deny case, one tier looser: an `ask` the user set
        // is still a decision about the capability, not about a string.
        let existing: [String: Any] = [
            "permissions": ["ask": ["mcp__mootx01__moot_memory_search"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        #expect(ask.contains("mcp__mootx01__moot_memory_search"), "the user's ask must survive untouched")
        #expect(ask.contains("mcp__plugin_mootx01_memory__moot_memory_search"), "the absent plugin twin must inherit ask")
        #expect(!allow.contains("mcp__plugin_mootx01_memory__moot_memory_search"), "must not take classify's allow default")
    }

    @Test("inheritance is symmetric: a plugin-namespace deny binds the absent direct twin")
    func mergeTieredPluginDenyBindsAbsentDirectTwin() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // The mirror image. Neither prefix is privileged — whichever one
        // carries the user's decision is the one the other inherits from.
        let existing: [String: Any] = [
            "permissions": ["deny": ["mcp__plugin_mootx01_memory__moot_memory_search"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        #expect(deny.contains("mcp__plugin_mootx01_memory__moot_memory_search"), "the user's deny must survive untouched")
        #expect(deny.contains("mcp__mootx01__moot_memory_search"), "the absent direct twin must inherit deny")
        #expect(!allow.contains("mcp__mootx01__moot_memory_search"), "must not take classify's allow default")
    }

    @Test("siblings that disagree are both left exactly where the user put them")
    func mergeTieredDisagreeingSiblingsAreNeverMoved() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // One namespace allowed, the other denied. With both entries present
        // there is nothing left to add for this tool, so the observable
        // guarantee is that mergeTiered MOVES NEITHER — inheritance decides
        // the tier of new entries only and is never a licence to re-tier an
        // existing one (that is migrateTiers' job, and deny is sacred there).
        // The most-restrictive tie-break itself is unreachable while there
        // are exactly two namespaces: a disagreement implies both entries
        // exist, so no entry is added to apply it to. It is defensive, and
        // becomes observable only if a third prefix is ever added.
        let existing: [String: Any] = [
            "permissions": [
                "allow": ["mcp__mootx01__moot_memory_search"],
                "deny": ["mcp__plugin_mootx01_memory__moot_memory_search"],
            ]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        #expect(allow.contains("mcp__mootx01__moot_memory_search"), "the user's allow must stay put")
        #expect(deny.contains("mcp__plugin_mootx01_memory__moot_memory_search"), "the user's deny must stay put")
        #expect(!deny.contains("mcp__mootx01__moot_memory_search"), "the allowed entry must not be duplicated into deny")
        #expect(!allow.contains("mcp__plugin_mootx01_memory__moot_memory_search"), "the denied entry must not be duplicated into allow")
        #expect(!ask.contains("mcp__mootx01__moot_memory_search") && !ask.contains("mcp__plugin_mootx01_memory__moot_memory_search"))
    }

    @Test("with neither namespace present the classifier default still decides")
    func mergeTieredFallsBackToClassifyWhenNoSiblingExists() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        // The unchanged path: inheritance only fires when a sibling exists.
        // A settings file carrying an unrelated tool must not perturb how
        // moot_erase_memory (deny) or moot_withdraw_memory (ask) are tiered.
        let existing: [String: Any] = [
            "permissions": ["deny": ["mcp__mootx01__moot_estate_ping"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)

        let perms = try readPermissions(settingsURL)
        let allow = perms["allow"] as? [String] ?? []
        let ask = perms["ask"] as? [String] ?? []
        let deny = perms["deny"] as? [String] ?? []
        for prefix in ["mcp__mootx01__", "mcp__plugin_mootx01_memory__"] {
            #expect(deny.contains("\(prefix)moot_erase_memory"), "destructive default unchanged under \(prefix)")
            #expect(ask.contains("\(prefix)moot_withdraw_memory"), "mutation default unchanged under \(prefix)")
            #expect(allow.contains("\(prefix)moot_memory_search"), "read default unchanged under \(prefix)")
        }
        // The unrelated tool's own inheritance still applies to ITS twin.
        #expect(deny.contains("mcp__plugin_mootx01_memory__moot_estate_ping"))
    }

    @Test("inheritance stays idempotent: a second run adds nothing")
    func mergeTieredInheritanceIsIdempotent() throws {
        let dir = try makeSandboxDir()
        defer { cleanupSandbox(dir) }

        let existing: [String: Any] = [
            "permissions": ["deny": ["mcp__mootx01__moot_memory_search"]]
        ]
        let settingsURL = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

        _ = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        let before = try readPermissions(settingsURL)

        let second = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
        #expect(second.allow == 0 && second.ask == 0 && second.deny == 0, "a second run must add nothing")

        let after = try readPermissions(settingsURL)
        for key in ["allow", "ask", "deny"] {
            #expect(
                (before[key] as? [String] ?? []) == (after[key] as? [String] ?? []),
                "\(key) must be byte-identical across runs"
            )
        }
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
                "allow": ["mcp__mootx01__moot_estate_ping", "mcp__plugin_mootx01_memory__moot_estate_ping"],
                "ask": [
                    "mcp__mootx01__moot_memory_search", "mcp__plugin_mootx01_memory__moot_memory_search",
                    "mcp__mootx01__moot_file_memory", "mcp__plugin_mootx01_memory__moot_file_memory",
                    "mcp__mootx01__moot_withdraw_memory", "mcp__plugin_mootx01_memory__moot_withdraw_memory",
                ],
                "deny": ["mcp__mootx01__moot_erase_memory", "mcp__plugin_mootx01_memory__moot_erase_memory"],
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
        #expect(allow.contains("mcp__plugin_mootx01_memory__moot_memory_search"))
        #expect(allow.contains("mcp__mootx01__moot_file_memory"))
        #expect(allow.contains("mcp__plugin_mootx01_memory__moot_file_memory"))
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
        try JSONSerialization.data(withJSONObject: ["permissions": ["deny": ["mcp__plugin_mootx01_memory__moot_erase_memory"]]])
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
            #expect(allow.contains("mcp__plugin_mootx01_memory__\(tool)"))
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
            #expect(!list.contains { $0.hasPrefix("mcp__plugin_mootx01_memory__") }, "\(key) must hold no plugin-namespace entries")
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
                "mcp__plugin_mootx01_memory__moot_capture_drawer",
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
        #expect(!allow.contains("mcp__plugin_mootx01_memory__moot_capture_drawer"), "stale plugin-namespace entry must be removed")
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
