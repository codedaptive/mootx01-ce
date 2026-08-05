import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP
@testable import GeniusLocusKit

/// The `sensitivity_advisory:` line on `moot_memory_search` and
/// `moot_memory_get` — proof that its presence depends on GRANT STATE ALONE.
///
/// The advisory once carried a second condition: an estate-contents probe that
/// issued an explicit exact `.sensitivity(.restricted)` / `.sensitivity(.secret)`
/// recall filter. Per `BitmapEvaluator.insertDefaults`, an explicit sensitivity
/// filter SUPPRESSES the default `sensitivityAtMost(.elevated)` ceiling, so that
/// probe saw straight through the gate it was reporting on. Advisory presence
/// then told any ungranted caller whether the estate held restricted or secret
/// rows — an estate-wide existence oracle reachable from ordinary read tools.
///
/// The regression test is `advisoryIsIndistinguishableBetweenEstates...`: two
/// estates that differ ONLY in whether a restricted row exists must produce
/// identical advisory behaviour for a caller holding no grant. Against the
/// pre-fix code that assertion fails, because the clean estate emitted no
/// advisory at all.
///
/// NOTHING here asserts that the advisory correlates with sensitive-row
/// existence. Such a test would re-pin the oracle.
@Suite("sensitivity advisory — presence depends on grant state, never on estate contents", .serialized)
struct SensitivityAdvisoryTests {

    /// The exact search-tool advisory. Byte-identical to the Rust port's
    /// literal in `rust/tests/sensitivity_advisory_tests.rs`; pinning it in
    /// both ports is what keeps the two wordings from drifting apart.
    static let searchAdvisory =
        "sensitivity_advisory: a sensitivity tier gate is in effect — " +
        "run `mootx01 unlock private` to include restricted memories, " +
        "`mootx01 unlock secret` for secret memories."

    /// The exact get-tool advisory. Search and get keep distinct phrasings.
    static let getAdvisory =
        "sensitivity_advisory: a sensitivity tier gate is in effect on this estate — " +
        "run `mootx01 unlock private` to include restricted memories, " +
        "`mootx01 unlock secret` for secret memories."

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    @discardableResult
    private func seed(
        _ content: String,
        sensitivity: AdjectiveSensitivity,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content, channel: .typed, room: "advisory-tests",
            latticeAnchor: .udc("004"), addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1", sensitivity: sensitivity,
            subject: String(content.prefix(120))
        )
        return try await kit.capture(handle, frame)
    }

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Every advisory line in a reply, in order. Comparing THIS between two
    /// replies is the indistinguishability check — comparing whole bodies
    /// would fail on unrelated differences (row ids, hit counts).
    private func advisories(in body: String) -> [String] {
        body.components(separatedBy: "\n")
            .filter { $0.hasPrefix("sensitivity_advisory: ") }
    }

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// A pair of estates identical in every respect the advisory could
    /// legitimately depend on, differing ONLY in whether a restricted row and
    /// a secret row exist. Both carry the same visible row, so both can be
    /// searched and fetched the same way.
    private struct EstatePair {
        let kit: GeniusLocusKit
        let clean: ToolDispatcher
        let sensitive: ToolDispatcher
        /// The visible row present in BOTH estates, by id.
        let cleanVisibleID: String
        let sensitiveVisibleID: String
    }

    private func makeEstatePair() async throws -> EstatePair {
        let kit = GeniusLocusKit()

        let cleanHandle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "advisory-clean"))
        let sensitiveHandle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "advisory-sensitive"))

        // The one row both estates share — ordinary, admitted by the default gate.
        let cleanVisible = try await seed(
            "advisory-marker ordinary visible content",
            sensitivity: .normal, in: cleanHandle, kit: kit)
        let sensitiveVisible = try await seed(
            "advisory-marker ordinary visible content",
            sensitivity: .normal, in: sensitiveHandle, kit: kit)

        // The ONLY difference between the two estates.
        try await seed("advisory-marker classified briefing",
                       sensitivity: .restricted, in: sensitiveHandle, kit: kit)
        try await seed("advisory-marker top secret payload",
                       sensitivity: .secret, in: sensitiveHandle, kit: kit)

        return EstatePair(
            kit: kit,
            clean: ToolDispatcher(kit: kit, handle: cleanHandle),
            sensitive: ToolDispatcher(kit: kit, handle: sensitiveHandle),
            cleanVisibleID: cleanVisible.id,
            sensitiveVisibleID: sensitiveVisible.id
        )
    }

    // MARK: - No grant, no sensitive rows → advisory present

    /// The case that proves the oracle is gone. Pre-fix, an estate with no
    /// restricted or secret rows emitted NO advisory, and that silence was the
    /// disclosure.
    @Test("search: with no grant, an estate holding no sensitive rows still emits the advisory")
    func searchAdvisoryPresentOnCleanEstateWithoutGrant() async throws {
        let pair = try await makeEstatePair()

        let body = text(of: try await pair.clean.runMemorySearch(
            ["query": .string("advisory-marker")]))

        #expect(advisories(in: body) == [Self.searchAdvisory],
                "the gate is in effect, so the advisory must be emitted verbatim regardless of contents")
    }

    @Test("get: with no grant, an estate holding no sensitive rows still emits the advisory")
    func getAdvisoryPresentOnCleanEstateWithoutGrant() async throws {
        let pair = try await makeEstatePair()

        let body = text(of: try await pair.clean.runMemoryGet(
            ["id": .string(pair.cleanVisibleID)]))

        #expect(advisories(in: body) == [Self.getAdvisory])
    }

    // MARK: - The regression test: indistinguishability

    /// Two estates differing ONLY in whether restricted/secret rows exist must
    /// produce IDENTICAL advisory behaviour for an ungranted caller. This is
    /// the assertion that fails against the pre-fix code.
    @Test("search: the advisory is identical across estates that differ only in sensitive-row contents")
    func searchAdvisoryIsIndistinguishableBetweenEstatesWithoutGrant() async throws {
        let pair = try await makeEstatePair()
        let args: JSONValue = .object(["query": .string("advisory-marker")])

        let cleanBody = text(of: try await pair.clean.dispatch(
            name: "moot_memory_search", arguments: args))
        let sensitiveBody = text(of: try await pair.sensitive.dispatch(
            name: "moot_memory_search", arguments: args))

        #expect(advisories(in: cleanBody) == advisories(in: sensitiveBody),
                "advisory behaviour must not distinguish an estate with sensitive rows from one without")
        #expect(advisories(in: cleanBody) == [Self.searchAdvisory],
                "and both must be the real advisory, not a shared absence")

        // The gate itself still works: the restricted/secret bodies never leak.
        #expect(!sensitiveBody.contains("classified briefing"))
        #expect(!sensitiveBody.contains("top secret payload"))
    }

    @Test("get: the advisory is identical across estates that differ only in sensitive-row contents")
    func getAdvisoryIsIndistinguishableBetweenEstatesWithoutGrant() async throws {
        let pair = try await makeEstatePair()

        let cleanBody = text(of: try await pair.clean.runMemoryGet(
            ["id": .string(pair.cleanVisibleID)]))
        let sensitiveBody = text(of: try await pair.sensitive.runMemoryGet(
            ["id": .string(pair.sensitiveVisibleID)]))

        #expect(advisories(in: cleanBody) == advisories(in: sensitiveBody),
                "fetching a visible row must disclose nothing about other rows' existence")
        #expect(advisories(in: cleanBody) == [Self.getAdvisory])
    }

    /// The mission's fourth case, stated directly: a successful by-id fetch of
    /// an ordinary row must carry no signal about what else the estate holds.
    /// The reply differs from the clean estate's ONLY in the row's own fields.
    @Test("get: a visible row's reply discloses nothing about other rows in either estate")
    func getOfVisibleRowDisclosesNothingAboutOtherRows() async throws {
        let pair = try await makeEstatePair()

        let cleanBody = text(of: try await pair.clean.runMemoryGet(
            ["id": .string(pair.cleanVisibleID)]))
        let sensitiveBody = text(of: try await pair.sensitive.runMemoryGet(
            ["id": .string(pair.sensitiveVisibleID)]))

        for body in [cleanBody, sensitiveBody] {
            #expect(body.contains("ordinary visible content"))
            #expect(!body.contains("classified briefing"))
            #expect(!body.contains("top secret payload"))
            #expect(!body.lowercased().contains("restricted memories found"))
        }

        // Normalise away the row's own identity; what remains must match
        // line-for-line between the two estates.
        func shape(_ body: String, id: String) -> [String] {
            body.components(separatedBy: "\n").map { line in
                line.replacingOccurrences(of: id, with: "<id>")
            }.filter {
                // Per-row provenance fields legitimately differ (timestamps,
                // lineage uuid); the SHAPE is what must not vary.
                !$0.hasPrefix("filed_at: ") && !$0.hasPrefix("event_time: ")
                    && !$0.hasPrefix("lineage: ")
            }
        }
        #expect(shape(cleanBody, id: pair.cleanVisibleID)
                == shape(sensitiveBody, id: pair.sensitiveVisibleID),
                "the two replies must be indistinguishable apart from the row's own provenance")
    }

    // MARK: - Live grant → advisory absent

    @Test("search: a live restricted grant suppresses the advisory in both estates")
    func searchAdvisoryAbsentUnderLiveGrantInBothEstates() async throws {
        let pair = try await makeEstatePair()
        let now = Date()
        await pair.clean.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)
        await pair.sensitive.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)

        let args: JSONValue = .object(["query": .string("advisory-marker")])
        let cleanBody = text(of: try await pair.clean.dispatch(
            name: "moot_memory_search", arguments: args))
        let sensitiveBody = text(of: try await pair.sensitive.dispatch(
            name: "moot_memory_search", arguments: args))

        #expect(advisories(in: cleanBody).isEmpty,
                "under a live grant the ceiling is lifted and no advisory applies")
        #expect(advisories(in: sensitiveBody).isEmpty)
    }

    @Test("get: a live restricted grant suppresses the advisory in both estates")
    func getAdvisoryAbsentUnderLiveGrantInBothEstates() async throws {
        let pair = try await makeEstatePair()
        let now = Date()
        await pair.clean.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)
        await pair.sensitive.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)

        let cleanBody = text(of: try await pair.clean.runMemoryGet(
            ["id": .string(pair.cleanVisibleID)]))
        let sensitiveBody = text(of: try await pair.sensitive.runMemoryGet(
            ["id": .string(pair.sensitiveVisibleID)]))

        #expect(advisories(in: cleanBody).isEmpty)
        #expect(advisories(in: sensitiveBody).isEmpty)
    }

    /// A secret-tier grant lifts the ceiling too, so it must also suppress the
    /// advisory — the condition is "a grant is live", not "the restricted
    /// grant specifically".
    @Test("search: a live secret grant also suppresses the advisory")
    func searchAdvisoryAbsentUnderLiveSecretGrant() async throws {
        let pair = try await makeEstatePair()
        await pair.sensitive.sensitivityUnlockLedger.grantSecret(now: Date())

        let body = text(of: try await pair.sensitive.runMemorySearch(
            ["query": .string("advisory-marker")]))

        #expect(advisories(in: body).isEmpty)
    }
}
