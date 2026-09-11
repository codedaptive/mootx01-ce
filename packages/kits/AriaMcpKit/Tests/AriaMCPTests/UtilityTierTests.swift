// UtilityTierTests.swift
//
// PR-04 verification: the estate-status subject-debt counter on a mixed
// fixture, and the terse/verbose catalogue tiers.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Utility tier — subject-debt counter + catalogue tiers", .serialized)
struct UtilityTierTests {

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// v2 diagnostics carry their typed payload in `structuredContent.data`
    /// (AriaV2EstateDiagnostics.swift:421-430), not in the rendered
    /// `content[0].text`, which is now only a generic compact summary. Used
    /// by `estateStatusMemoryCountExcludesRestrictedRows` to pin the exact
    /// `memory_count` field.
    private func data(of result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    // MARK: - estate_status subject-debt counter — BLOCKED (v2 dropped the field)
    //
    // v1's `moot_estate_status` rendered free text ("subjects: X/Y (Z
    // missing)", "memories: N active (M total)", "wings: ...") via the
    // legacy `runEstateStatus` (ToolDispatch.swift:3503). The live v2
    // production path (`ToolDispatcher.dispatch` → `estateDiagnostics.status`,
    // ToolDispatch.swift:850-851) is `AriaV2GeniusLocusEstateDiagnosticsProvider.status`
    // (AriaV2EstateDiagnostics.swift:191-221), which returns a typed
    // `AriaV2EstateStatusData` (AriaV2EstateDiagnostics.swift:93-103):
    // `estateID`, `estateName`, `memoryCount`, `factCount`, `drains`,
    // `fdcRecalculation` — there is no subject/subject-debt field anywhere
    // in that struct or its `.json` projection (AriaV2EstateDiagnostics.swift:421-430),
    // and the response's `compactText` is the generic "moot_estate_status
    // completed for estate <uuid>." (AriaV2EstateDiagnostics.swift:402), not
    // a rendered text block. `memoryCount` DOES still apply the same
    // sensitivity ceiling (`adjectiveSensitivity.isBulkExportable`,
    // AriaV2EstateDiagnostics.swift:195) v1's "memories: N active" reflected,
    // but the subject-bearing/missing counter itself has no v2 home to
    // redirect the pinned assertion to. Awaiting catalog decision on whether
    // moot_estate_status should regain a subject-debt field. Do not delete;
    // do not weaken to pass.

    @Test(.disabled("BLOCKED: v2 moot_estate_status (AriaV2EstateDiagnostics.swift:191-221, AriaV2EstateStatusData at AriaV2EstateDiagnostics.swift:93-103) has no subject-debt field at all — the response is typed (memoryCount, factCount, drains, fdcRecalculation) with a generic compactText (AriaV2EstateDiagnostics.swift:402), not the v1 'subjects: X/Y (Z missing)' / 'memories: N active (M total)' text lines rendered only by the dead legacy runEstateStatus (ToolDispatch.swift:3503), unreachable from ToolDispatcher.dispatch(name:arguments:). Pinned assertion cannot pass against v2 behavior; there is no v2 field to redirect it to. Do not delete; do not weaken to pass."))
    func estateStatusShowsSubjectDebtOnMixedFixture() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "debt-counter"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "debt-counter"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Two subject-bearing rows through the boundary…
        for i in 1...2 {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("Fixture row \(i) with a subject."),
                    "subject": .string("Fixture row \(i): has a subject."),
                    "location": .string("debt-tests"),
                ]))
        }
        // …and one subject-less row through the direct seam (intake shape).
        let frame = CaptureFrame(
            content: "Imported fixture row without a subject.",
            channel: .actuator,
            room: "debt-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "utility-tier-tests",
            embeddingModelID: "default",
            wing: LocusKit.defaultWingName)
        _ = try await kit.capture(handle, frame, mode: .regular)

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: status)
        // 2 subject-bearing / 3 eligible (1 missing). The bare estate here
        // has no seeded charter hints (Estate.create path), so the counts
        // are exactly the fixture's.
        #expect(body.contains("subjects: 2/3 (1 missing)"),
                "debt counter must reflect the mixed fixture; got: \(body)")
        // Over-filtering control (MXE-XU): every row here is normal
        // sensitivity, so the sensitivity ceiling removes nothing and the
        // counts are identical to what they were before the ceiling was
        // applied to them. An estate with no restricted rows must read the
        // same after the fix as before it.
        #expect(body.contains("memories: 3 active (3 total)"),
                "ceiling must not drop rows on an estate with no restricted rows; got: \(body)")
    }

    /// MXE-XU — every drawer-derived aggregate on this surface reads the
    /// sensitivity-filtered set, not the raw cluster-A set.
    ///
    /// The fixture holds one visible subject-bearing row plus two restricted
    /// rows — one carrying a subject, one not — filed into a wing of their
    /// own. Before the fix this reported `memories: 3 active (3 total)` and
    /// `subjects: 2/3 (1 missing)`: an ungranted caller learned that live rows
    /// were hidden from it, how many, and how many of those carried a subject.
    /// `wings:` was already filtered; it is the control that proves the fix
    /// closes the leak without over-reaching.
    ///
    /// v2 reshape: BLOCKED, same reason as `estateStatusShowsSubjectDebtOnMixedFixture`
    /// above — no subject-debt field, and no `wings:` text (wing listing now
    /// lives only in the separate `moot_estate_map` response,
    /// AriaV2EstateDiagnostics.swift:223-245). The aggregate-exclusion half
    /// of this property — restricted rows must not count toward
    /// `memory_count` — is now covered live by
    /// `estateStatusMemoryCountExcludesRestrictedRows` below; this block
    /// covers only the subject-debt counter and wing-naming assertions,
    /// which have no v2 field to redirect to.
    @Test(.disabled("BLOCKED: same as estateStatusShowsSubjectDebtOnMixedFixture — v2 AriaV2EstateStatusData (AriaV2EstateDiagnostics.swift:93-103) has no subject-debt field and no wings text (wings moved to the separate moot_estate_map response, AriaV2EstateDiagnostics.swift:223-245). The v1 'subjects: 1/1 (0 missing)', 'memories: 1 active (1 total)', and 'wings: ...' text lines exist only on the dead legacy runEstateStatus (ToolDispatch.swift:3503), unreachable from ToolDispatcher.dispatch(name:arguments:). Pinned assertion cannot pass against v2 behavior; there is no v2 field to redirect it to. The aggregate-exclusion half of this property is now covered by estateStatusMemoryCountExcludesRestrictedRows below; this block covers only the subject-debt counter and wing-naming assertions. Do not delete; do not weaken to pass."))
    func estateStatusAggregatesExcludeRestrictedRows() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "xu-ceiling"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "xu-ceiling"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let hiddenWing = "Ceiling Hidden Wing"

        // One normal-sensitivity, subject-bearing row in the default wing.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Visible row with a subject."),
                "subject": .string("Visible row: carries a subject."),
                "location": .string("ceiling-tests"),
            ]))

        // One restricted row WITH a subject, in a wing of its own.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Restricted row with a subject."),
                "subject": .string("Restricted row: carries a subject."),
                "location": .string("ceiling-hidden"),
                "wing": .string(hiddenWing),
                "sensitivity": .string("restricted"),
            ]))

        // …and one restricted row WITHOUT a subject. The ARIA boundary
        // requires a subject, so subject debt is seeded through the direct
        // capture seam, as the mixed-fixture test above does.
        let frame = CaptureFrame(
            content: "Restricted row without a subject.",
            channel: .actuator,
            room: "ceiling-hidden",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "utility-tier-tests",
            embeddingModelID: "default",
            sensitivity: .restricted,
            wing: hiddenWing)
        _ = try await kit.capture(handle, frame, mode: .regular)

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: status)

        // The subject counter sees one eligible row, and it bears a subject.
        #expect(body.contains("subjects: 1/1 (0 missing)"),
                "subject counter must count only sensitivity-visible rows; got: \(body)")
        // The memories counts move with the same set — a count that tracks
        // the restricted population is the same leak in scalar form.
        #expect(body.contains("memories: 1 active (1 total)"),
                "memory counts must exclude restricted rows; got: \(body)")
        // Already-correct neighbour: the restricted rows' wing must not be
        // named, and the default wing must still be.
        #expect(!body.contains(hiddenWing),
                "wing listing must not name a wing known only from restricted rows; got: \(body)")
        #expect(body.contains("wings: \(LocusKit.defaultWingName)"),
                "the visible row's wing must still be listed; got: \(body)")
    }

    /// Live coverage for the aggregate-exclusion half of the property
    /// blocked whole on `estateStatusAggregatesExcludeRestrictedRows`
    /// (above). `AriaV2EstateDiagnostics.status`
    /// (AriaV2EstateDiagnostics.swift:191-215) computes `memoryCount` from
    /// `drawers.filter { $0.tombstonedAt == nil &&
    /// $0.adjectiveSensitivity.isBulkExportable }` — the same sensitivity
    /// ceiling v1's `memories: N active (M total)` line proved. Blocking
    /// the whole legacy case left that property with zero coverage
    /// anywhere in the suite; this case pins it directly against the typed
    /// v2 `memory_count` field so a regression that let restricted rows
    /// back into the count fails the suite.
    @Test func estateStatusMemoryCountExcludesRestrictedRows() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "xu-count"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "xu-count"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // One visible, normal-sensitivity row in the default wing.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Visible row with a subject."),
                "subject": .string("Visible row: carries a subject."),
                "location": .string("count-tests"),
            ]))

        // One restricted row, in a wing of its own — must not count.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Restricted row with a subject."),
                "subject": .string("Restricted row: carries a subject."),
                "location": .string("count-hidden"),
                "wing": .string("Count Hidden Wing"),
                "sensitivity": .string("restricted"),
            ]))

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let memoryCount = data(of: status)?["memory_count"]

        #expect(memoryCount == .integer(1),
                "memory_count must exclude the restricted row; got \(String(describing: memoryCount))")
    }

    // MARK: - list_lenses terse/verbose — BLOCKED (v2 verbose arg is a no-op)
    //
    // v1's `moot_list_lenses` rendered a prose-only terse block by default,
    // and a longer prose block with "Required: " lines when `verbose:true`
    // (RecipeTools.swift:660-678, the legacy runner). The live v2 path
    // (`ToolDispatcher.dispatch` → `cognitionCatalog.lenses(request)`,
    // ToolDispatch.swift:860-861) is `AriaV2CognitionCatalogService.lenses`
    // (AriaV2CognitionCatalog.swift:43-59), whose doc comment states
    // explicitly: "v2 returns the complete structured projection instead of
    // a prose-only terse/verbose rendering" (AriaV2CognitionCatalog.swift:6-7).
    // `request.verbose` is decoded then discarded (`_ = request.verbose`,
    // AriaV2CognitionCatalog.swift:45) — terse and verbose calls produce
    // byte-identical output ("Listed N callable cognition tools.",
    // AriaV2CognitionCatalog.swift:58), and no response ever contains
    // "Required: " as a text line (required args live only in each tool's
    // structured `input_schema`, AriaV2CognitionCatalog.swift:52). v1's
    // `verbose.count > terse.count` and `verbose.contains("Required: ")`
    // assertions cannot pass against v2 behavior — there is no verbose/terse
    // distinction left to redirect them to. Do not delete; do not weaken to
    // pass.

    @Test(.disabled("BLOCKED: v2 moot_list_lenses (AriaV2CognitionCatalog.swift:43-59) explicitly ignores the verbose argument (`_ = request.verbose`, AriaV2CognitionCatalog.swift:45) — per the type's own doc comment (AriaV2CognitionCatalog.swift:6-7) v2 always returns the same structured projection regardless of verbose. terse and verbose calls are byte-identical; no response ever contains a 'Required: ' text line. Pinned assertions (verbose.count > terse.count, verbose.contains(\"Required: \")) cannot pass against v2 behavior. Do not delete; do not weaken to pass."))
    func listLensesTerseDefaultAndVerbose() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "catalogue"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "catalogue"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let terse = text(of: try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:])))
        #expect(terse.contains("cognition tools"))
        #expect(terse.contains("(terse — pass verbose:true"))
        #expect(!terse.contains("Required: "),
                "terse mode must not include the required-args blocks")

        let verbose = text(of: try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object(["verbose": .bool(true)])))
        #expect(verbose.contains("Required: "))
        #expect(verbose.count > terse.count,
                "verbose must be larger than terse (terse \(terse.count) vs verbose \(verbose.count))")

        let terseRecipes = text(of: try await dispatcher.dispatch(
            name: "moot_list_recipes", arguments: .object([:])))
        #expect(terseRecipes.contains("recipe(s)"))
        #expect(terseRecipes.contains("(terse — pass verbose:true"))
        let verboseRecipes = text(of: try await dispatcher.dispatch(
            name: "moot_list_recipes", arguments: .object(["verbose": .bool(true)])))
        #expect(verboseRecipes.contains("requires: "))
    }
}
