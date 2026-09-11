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

    /// The restored fields, asserted structurally. Three of them
    /// (recall_trace_count, sync_state, shared_content_migration) were
    /// reachable only from the v1 dispatch table and had no test at all in
    /// either generation, which is how they went missing unnoticed.
    @Test func estateStatusCarriesSubjectDebtAndDiagnosticFields() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "status-fields"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "status-fields"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("a memory that carries a subject"),
                "subject": .string("carries a subject"),
                "location": .string("study"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let data = try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)

        #expect(data["subjects_eligible"]?.integerValue == 1,
                "one non-empty memory is eligible for a subject")
        #expect(data["subjects_bearing"]?.integerValue == 1,
                "and it carries one, so the debt is zero")
        // Always present: "local-only" when no sync engine is wired, never absent.
        #expect(data["sync_state"]?.stringValue != nil)
        // Omitted rather than zeroed when unreadable, so a present value is
        // a real count and absence is not silently reported as an empty table.
        if let traces = data["recall_trace_count"] {
            #expect(traces.integerValue != nil)
        }
    }

    @Test(.disabled("CONVERSION PENDING (was BLOCKED on a missing field). The data is restored: moot_estate_status now carries subjects_bearing and subjects_eligible, plus recall_trace_count, sync_state and shared_content_migration, all four of which were reachable only through the v1 dispatch table. What this case still pins is v1 RENDERED TEXT -- \"subjects: 1/1 (0 missing)\", \"memories: 1 active (1 total)\", \"wings: ...\" -- and v2 answers structurally by ruling. estateStatusCarriesSubjectDebtAndDiagnosticFields below asserts the same facts against the structured payload. Redirecting these greps is like-for-like. Do not delete; do not weaken to pass."))
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
    @Test(.disabled("CONVERSION PENDING (was BLOCKED on a missing field). The data is restored: moot_estate_status now carries subjects_bearing and subjects_eligible, plus recall_trace_count, sync_state and shared_content_migration, all four of which were reachable only through the v1 dispatch table. What this case still pins is v1 RENDERED TEXT -- \"subjects: 1/1 (0 missing)\", \"memories: 1 active (1 total)\", \"wings: ...\" -- and v2 answers structurally by ruling. estateStatusCarriesSubjectDebtAndDiagnosticFields below asserts the same facts against the structured payload. Redirecting these greps is like-for-like. Do not delete; do not weaken to pass."))
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

    // MARK: - list_lenses terse/verbose

    @Test
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

        let terseResult = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:]))
        let terse = text(of: terseResult)
        #expect(terse.contains("cognition tools"))
        #expect(terse.contains("(terse — pass verbose:true"))
        #expect(!terse.contains("Required: "),
                "terse mode must not include the required-args blocks")

        let verboseResult = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object(["verbose": .bool(true)]))
        let verbose = text(of: verboseResult)
        // v1 rendered required args as "Required: arg" prose; v2 carries the
        // same information as machine-readable JSON in input_schema["required"].
        // Redirect to the structural equivalent: verbose row carries input_schema,
        // terse row omits it entirely.
        let verboseFirstTool = data(of: verboseResult)?["tools"]?.arrayValue?.first?.objectValue
        let terseFirstTool = data(of: terseResult)?["tools"]?.arrayValue?.first?.objectValue
        #expect(verboseFirstTool?["input_schema"] != nil,
                "verbose mode must carry input_schema (the required array lives inside it)")
        #expect(terseFirstTool?["input_schema"] == nil,
                "terse mode must omit input_schema")
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

    /// Pins the EXACT key set of a verbose `moot_list_lenses` row, so the Swift
    /// and Rust ports are compared field for field rather than each port being
    /// checked only against itself. The Rust twin is
    /// `cognition_catalog_v2_verbose_row_key_set_matches_swift`
    /// (rust/tests/utility_tier_tests.rs).
    ///
    /// `output_schema` is present when the tool declares one and the key is
    /// OMITTED when it does not. Neither port may emit a null `output_schema`:
    /// absent in one port and null in the other is a conformance failure.
    /// Swift omits via `if let` in `buildOutputSchemaLookup`'s consumer; Rust
    /// omits via `.get("outputSchema").filter(!is_null).cloned()` plus
    /// `skip_serializing_if`.
    @Test
    func verboseLensRowKeySetIsExact() async throws {
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

        // Empirical check that motivates the omit-on-absent branch: how many
        // callable cognition tools carry no declared output schema. Every v2
        // operation supplies one through
        // AriaV2OperationDescriptor.projectedTool() (outputSchema:
        // projection.outputSchema, non-optional), so this is expected to be 0
        // today. The branch still has to agree across ports.
        let callableNames = Set(
            (RecipeTools.tools() + LensTools.tools()).map(\.name))
        let projected = ToolProjection.tools().filter { callableNames.contains($0.name) }
        let missingOutputSchema = projected.filter { $0.outputSchema == nil }
        #expect(missingOutputSchema.isEmpty,
                "callable cognition tools with no output schema: \(missingOutputSchema.map(\.name))")

        let verboseResult = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object(["verbose": .bool(true)]))
        let verboseRows = try #require(
            data(of: verboseResult)?["tools"]?.arrayValue, "verbose must return tool rows")
        #expect(!verboseRows.isEmpty, "the verbose row set must not be empty")

        for row in verboseRows {
            let obj = try #require(row.objectValue)
            let name = try #require(obj["name"]?.stringValue)
            let keys = Set(obj.keys)
            // No port may ever emit a null output_schema.
            #expect(obj["output_schema"] != JSONValue.null,
                    "\(name): output_schema must be omitted, never null")
            if obj["output_schema"] == nil {
                #expect(keys == ["name", "description", "input_schema"],
                        "\(name) verbose key set without an output schema: \(keys.sorted())")
            } else {
                #expect(keys == ["name", "description", "input_schema", "output_schema"],
                        "\(name) verbose key set: \(keys.sorted())")
            }
        }

        // The terse row is the same key set minus both schemas.
        let terseResult = try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:]))
        let terseRows = try #require(data(of: terseResult)?["tools"]?.arrayValue)
        for row in terseRows {
            let obj = try #require(row.objectValue)
            let name = try #require(obj["name"]?.stringValue)
            #expect(Set(obj.keys) == ["name", "description"],
                    "\(name) terse key set: \(Set(obj.keys).sorted())")
        }
    }
}
