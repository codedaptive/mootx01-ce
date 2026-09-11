import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

/// Dispatch-surface coverage for the 7 ARIA v2 lens operations that route through
/// AriaV2LensLower.supported → AriaV2LensLowerService.execute() in the production
/// ToolDispatcher. Each happy-path test calls the production dispatcher and asserts
/// on payload values that would change if the handler were swapped for a stub.
///
/// FINDING — moot_lens_overlap: the production dispatcher always passes an empty
/// comparisonHandles dict to AriaV2LensLowerService (ToolDispatch.swift
/// executeV2Core, line ~726), so every overlap request resolves to isError:true.
/// This is recorded as current behaviour; a fix requires wiring the registered
/// estates map into lensLower.context.comparisonHandles in executeV2Core.
@Suite("ARIA v2 lens operations dispatched through production ToolDispatcher")
struct AriaV2LensDispatchCoverageTests {

    // BenchClock reads MOOT_BENCH_EPOCH_NOW from the injected environment dict.
    // The pinned value keeps test results deterministic across wall-clock drift.
    private static let pinnedEnvironment = [BenchClock.envKey: "2026-09-08T00:00:00Z"]

    /// Creates a production ToolDispatcher backed by an in-memory estate.
    /// Mirrors the makeDispatcher helper in AriaSurfaceV2Tests.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-lens-dispatch-coverage-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle, environment: Self.pinnedEnvironment)
    }

    /// Reads the tool name from structuredContent — the field that changes when
    /// the wrong handler runs.
    private func tool(_ result: JSONValue) -> String {
        result.objectValue?["structuredContent"]?.objectValue?["tool"]?.stringValue ?? ""
    }

    /// Reads the data object from structuredContent.
    private func data(_ result: JSONValue) -> [String: JSONValue] {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue ?? [:]
    }

    /// Returns the isError flag; defaults to true so missing fields count as errors.
    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? true
    }

    // MARK: - Happy paths

    @Test("moot_lens_anticipate dispatches through lower service and returns actions shape")
    func anticipateHappyPath() async throws {
        let d = try await makeDispatcher()
        // targetKind is required by the schema; "prose" is a valid content kind name.
        let result = try await d.dispatch(
            name: "moot_lens_anticipate",
            arguments: .object(["targetKind": .string("prose")]))
        // Assertions that discriminate against a stub handler:
        // (1) isError would be true if the lower service refused; (2) tool would be
        // wrong if the wrong handler ran; (3) actions key would be absent if the
        // response shape is wrong.
        #expect(!isError(result), "anticipate must succeed; got: \(result)")
        #expect(
            tool(result) == "moot_lens_anticipate",
            "structuredContent.tool must round-trip the operation name; got: \(tool(result))")
        #expect(
            data(result)["actions"] != nil,
            "structuredContent.data must carry actions key; got: \(data(result))")
    }

    @Test("moot_lens_bias dispatches through lower service and returns bias shape")
    func biasHappyPath() async throws {
        let d = try await makeDispatcher()
        // No required args for bias.
        let result = try await d.dispatch(
            name: "moot_lens_bias",
            arguments: .object([:]))
        #expect(!isError(result), "bias must succeed; got: \(result)")
        #expect(
            tool(result) == "moot_lens_bias",
            "structuredContent.tool must round-trip; got: \(tool(result))")
        #expect(
            data(result)["biasedFor"] != nil,
            "structuredContent.data must carry biasedFor key; got: \(data(result))")
        #expect(
            data(result)["biasedAgainst"] != nil,
            "structuredContent.data must carry biasedAgainst key; got: \(data(result))")
    }

    @Test("moot_lens_constellation dispatches through lower service and returns communities shape")
    func constellationHappyPath() async throws {
        let d = try await makeDispatcher()
        // wing is required by the schema.
        let result = try await d.dispatch(
            name: "moot_lens_constellation",
            arguments: .object(["wing": .string("work")]))
        #expect(!isError(result), "constellation must succeed; got: \(result)")
        #expect(
            tool(result) == "moot_lens_constellation",
            "structuredContent.tool must round-trip; got: \(tool(result))")
        #expect(
            data(result)["communities"] != nil,
            "structuredContent.data must carry communities key; got: \(data(result))")
    }

    @Test("moot_lens_drift dispatches through lower service and returns drift shape")
    func driftHappyPath() async throws {
        let d = try await makeDispatcher()
        // splitAt is required by the schema; ISO8601 string.
        let result = try await d.dispatch(
            name: "moot_lens_drift",
            arguments: .object(["splitAt": .string("2026-01-01T00:00:00Z")]))
        #expect(!isError(result), "drift must succeed; got: \(result)")
        #expect(
            tool(result) == "moot_lens_drift",
            "structuredContent.tool must round-trip; got: \(tool(result))")
        #expect(
            data(result)["beforeCount"] != nil,
            "structuredContent.data must carry beforeCount key; got: \(data(result))")
        #expect(
            data(result)["afterCount"] != nil,
            "structuredContent.data must carry afterCount key; got: \(data(result))")
    }

    @Test("moot_lens_latent_themes dispatches through lower service and returns themes shape")
    func latentThemesHappyPath() async throws {
        let d = try await makeDispatcher()
        // No required args for latent_themes.
        let result = try await d.dispatch(
            name: "moot_lens_latent_themes",
            arguments: .object([:]))
        #expect(!isError(result), "latent_themes must succeed; got: \(result)")
        #expect(
            tool(result) == "moot_lens_latent_themes",
            "structuredContent.tool must round-trip; got: \(tool(result))")
        #expect(
            data(result)["k"] != nil,
            "structuredContent.data must carry k key; got: \(data(result))")
        #expect(
            data(result)["loadings"] != nil,
            "structuredContent.data must carry loadings key; got: \(data(result))")
    }

    @Test("moot_lens_rhythm dispatches through lower service and returns rhythm shape")
    func rhythmHappyPath() async throws {
        let d = try await makeDispatcher()
        // All four args are required by the schema; strings per the validated arg type.
        // bit=1 selects the operational bitmap, bucketSeconds/bucketCount define
        // the histogram shape, endingAt anchors the time window.
        let result = try await d.dispatch(
            name: "moot_lens_rhythm",
            arguments: .object([
                "bit": .string("1"),
                "bucketSeconds": .string("86400"),
                "bucketCount": .string("32"),
                "endingAt": .string("2026-12-31T23:59:59Z"),
            ]))
        #expect(!isError(result), "rhythm must succeed; got: \(result)")
        #expect(
            tool(result) == "moot_lens_rhythm",
            "structuredContent.tool must round-trip; got: \(tool(result))")
        #expect(
            data(result)["bucketCount"] != nil,
            "structuredContent.data must carry bucketCount key; got: \(data(result))")
        #expect(
            data(result)["periods"] != nil,
            "structuredContent.data must carry periods key; got: \(data(result))")
    }

    // MARK: - Overlap current-behaviour finding

    /// FINDING: moot_lens_overlap always returns isError:true through the production
    /// ToolDispatcher because executeV2Core (ToolDispatch.swift) constructs the
    /// AriaV2LensLowerService with context.comparisonHandles = [:] (always empty).
    /// The comparisonHandle() helper immediately throws a refusal when the supplied
    /// UUID is absent from the map, which AriaV2LensLowerService catches and converts
    /// to isError:true. This test records current behaviour — NOT correct behaviour.
    /// Fix: wire the dispatcher's registered estates into lensLower.context.comparisonHandles.
    @Test("moot_lens_overlap returns isError:true in production dispatcher (empty comparisonHandles — FINDING)")
    func overlapCurrentBehaviourIsRefusal() async throws {
        let d = try await makeDispatcher()
        // A well-formed UUID that is NOT registered in this dispatcher.
        // The lower service cannot resolve it from the empty comparisonHandles map,
        // so it refuses — which AriaV2LensLowerService converts to isError:true.
        let result = try await d.dispatch(
            name: "moot_lens_overlap",
            arguments: .object(["comparison_estate_id": .string("33333333-3333-4333-8333-333333333333")]))
        // CURRENT BEHAVIOUR: always isError:true (lower-authority refusal, not a throw).
        // The assertion on isError alone would pass if a stub handler returned any
        // isError:true result — including one with a wrong error code.  Asserting the
        // specific error code ensures the comparisonHandle() refusal path ran, not a
        // different failure.
        #expect(isError(result), "overlap must return isError:true when comparisonHandles is empty (current behaviour); got: \(result)")
        let errorCode = result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]?.stringValue
        #expect(
            errorCode == "lens_unavailable",
            "overlap refusal must carry code lens_unavailable (comparisonHandle refusal path); got: \(String(describing: errorCode))")
    }

    // MARK: - Error paths (dispatch() throws for missing required args)

    // These paths exercise the schema-decode layer: AriaV2RecallLensRequest
    // validates required args during init, throwing JSONRPCError before the
    // lower service is ever invoked. dispatch() propagates that throw to the caller.

    @Test("moot_lens_anticipate throws when targetKind is absent")
    func anticipateMissingTargetKindThrows() async throws {
        let d = try await makeDispatcher()
        await #expect(throws: (any Error).self, "dispatch must throw for missing required arg targetKind") {
            try await d.dispatch(name: "moot_lens_anticipate", arguments: .object([:]))
        }
    }

    @Test("moot_lens_constellation throws when wing is absent")
    func constellationMissingWingThrows() async throws {
        let d = try await makeDispatcher()
        await #expect(throws: (any Error).self, "dispatch must throw for missing required arg wing") {
            try await d.dispatch(name: "moot_lens_constellation", arguments: .object([:]))
        }
    }

    @Test("moot_lens_drift throws when splitAt is absent")
    func driftMissingSplitAtThrows() async throws {
        let d = try await makeDispatcher()
        await #expect(throws: (any Error).self, "dispatch must throw for missing required arg splitAt") {
            try await d.dispatch(name: "moot_lens_drift", arguments: .object([:]))
        }
    }

    @Test("moot_lens_rhythm throws when required args are absent")
    func rhythmMissingRequiredArgsThrows() async throws {
        let d = try await makeDispatcher()
        await #expect(throws: (any Error).self, "dispatch must throw for missing required rhythm args") {
            try await d.dispatch(name: "moot_lens_rhythm", arguments: .object([:]))
        }
    }
}
