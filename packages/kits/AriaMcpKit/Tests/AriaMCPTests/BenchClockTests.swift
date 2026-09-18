import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

// BenchClockTests — unit tests for the deterministic replay clock seam.
//
// Three surfaces under test:
//   A. BenchClock unit — provider returns pinned sequence under env, wall
//      clock without env. This is the primary gate: the seam must be
//      transparent when unpinned and deterministic when pinned.
//   B. ToolDispatcher integration — benchClock.isPinned reflects the env dict
//      the dispatcher was constructed with; the outer dispatch() calls
//      benchClock.now() so the seam is wired end-to-end (not just on BenchClock).
//   C. Schema surface — tool schemas carry no mention of MOOT_BENCH_EPOCH_NOW.
//      The env var is an internal measurement seam; leaking it into tool schemas
//      would break the contract and expose implementation details to MCP clients.

// MARK: - A. BenchClock unit tests

@Suite("BenchClock — pinned mode")
struct BenchClockPinnedTests {

    static let pinnedEnv = [BenchClock.envKey: "2026-07-25T00:00:00Z"]

    /// In pinned mode, now() returns base + 0s, base + 1s, base + 2s…
    @Test func pinnedModeReturnsBaseSequence() throws {
        let clock = BenchClock(environment: Self.pinnedEnv)
        #expect(clock.isPinned, "clock must be pinned when env key is set")

        let t0 = clock.now()
        let t1 = clock.now()
        let t2 = clock.now()

        // Each successive call advances by exactly 1 second.
        #expect(t1.timeIntervalSince(t0) == 1.0,
            "second call must be exactly 1s after first; got \(t1.timeIntervalSince(t0))")
        #expect(t2.timeIntervalSince(t1) == 1.0,
            "third call must be exactly 1s after second; got \(t2.timeIntervalSince(t1))")
    }

    /// Two independent BenchClock instances built from the same env produce the
    /// SAME sequence — same base, same counter starting at 0. This models two
    /// separate server launches from the same seed.
    @Test func twoInstancesFromSameSeedProduceSameSequence() {
        let c1 = BenchClock(environment: Self.pinnedEnv)
        let c2 = BenchClock(environment: Self.pinnedEnv)

        let t1a = c1.now()
        let t2a = c2.now()
        #expect(t1a == t2a, "first call from same env must produce identical Date")

        let t1b = c1.now()
        let t2b = c2.now()
        #expect(t1b == t2b, "second call from same env must produce identical Date")
    }

    /// Base instant matches the parsed ISO8601 value.
    @Test func baseInstantMatchesEnvValue() throws {
        let clock = BenchClock(environment: Self.pinnedEnv)
        let base = try #require(clock.pinnedBase, "pinnedBase must be non-nil in pinned mode")

        let fmt = ISO8601DateFormatter()
        let expected = try #require(fmt.date(from: "2026-07-25T00:00:00Z"),
            "test env value must be a valid ISO8601 instant")

        #expect(base == expected,
            "pinned base must equal the parsed env instant; got \(base)")
    }

    /// Fractional-seconds variant is accepted.
    @Test func fractionalSecondsVariantIsParsed() {
        let env = [BenchClock.envKey: "2026-07-25T12:30:45.500Z"]
        let clock = BenchClock(environment: env)
        #expect(clock.isPinned,
            "clock must be pinned when env key carries fractional-seconds instant")
    }
}

@Suite("BenchClock — wall-clock mode")
struct BenchClockWallClockTests {

    /// With no env key, isPinned is false and now() returns a fresh Date each time.
    @Test func wallClockModeNotPinned() {
        let clock = BenchClock(environment: [:])
        #expect(!clock.isPinned, "clock must NOT be pinned when env key is absent")
        #expect(clock.pinnedBase == nil, "pinnedBase must be nil in wall-clock mode")
    }

    /// now() in wall-clock mode returns Date() — verify it is close to real time
    /// (within 1 second, which proves it is not some fixed value).
    @Test func wallClockModeReturnsRealTime() {
        let clock = BenchClock(environment: [:])
        let before = Date()
        let t = clock.now()
        let after = Date()
        #expect(t >= before && t <= after,
            "wall-clock now() must fall within [before, after]; got \(t)")
    }

    /// Empty string value behaves the same as absent key — wall-clock mode.
    @Test func emptyEnvValueIsWallClockMode() {
        let clock = BenchClock(environment: [BenchClock.envKey: ""])
        #expect(!clock.isPinned,
            "empty env value must not activate pinned mode; isPinned should be false")
    }

    /// Unparseable value falls back to wall-clock mode (no crash).
    @Test func unparseableEnvValueIsWallClockMode() {
        let clock = BenchClock(environment: [BenchClock.envKey: "not-a-date"])
        #expect(!clock.isPinned,
            "unparseable env value must not activate pinned mode; isPinned should be false")
    }
}

// MARK: - B. ToolDispatcher integration

// Shared helper — provisions an in-memory GLK estate and wraps it in a
// ToolDispatcher built with the given environment dict. Mirrors
// ImpatientCaptureTests.makeDispatcherOnGLKEstate() exactly; the only
// delta is that environment is injected at the ToolDispatcher init site
// so tests can activate or deactivate the bench clock seam.
private func makeDispatcherWithEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "bench-clock-tests")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    let params = EstateProvisionParams(
        estateName: "BenchClock Test Estate",
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none
    )
    let handle = try await kit.provision(
        storage: storage, owner: owner, params: params,
        embeddingModels: [.deterministic])
    // Supply the environment dict so benchClock.isPinned reflects it
    // rather than ProcessInfo.processInfo.environment.
    let dispatcher = ToolDispatcher(kit: kit, handle: handle, environment: environment)
    return (dispatcher, kit, handle)
}

@Suite("BenchClock — ToolDispatcher integration")
struct BenchClockDispatcherIntegrationTests {

    /// A dispatcher built with MOOT_BENCH_EPOCH_NOW set must have isPinned == true.
    @Test func dispatcherPinsPinnedClock() async throws {
        let env = [BenchClock.envKey: "2026-07-25T06:00:00Z"]
        let (dispatcher, kit, handle) = try await makeDispatcherWithEnvironment(env)
        defer { Task { try? await kit.close(handle) } }

        #expect(dispatcher.benchClock.isPinned,
            "dispatcher built with bench epoch env must have benchClock.isPinned == true")
    }

    /// A dispatcher built without MOOT_BENCH_EPOCH_NOW must have isPinned == false.
    @Test func dispatcherWallClockWithoutEnv() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcherWithEnvironment([:])
        defer { Task { try? await kit.close(handle) } }

        #expect(!dispatcher.benchClock.isPinned,
            "dispatcher built without bench epoch env must have benchClock.isPinned == false")
    }
}

// MARK: - C. Schema surface — env var must NOT appear in tool schemas

@Suite("BenchClock — schema surface isolation")
struct BenchClockSchemaSurfaceTests {

    /// MOOT_BENCH_EPOCH_NOW must not appear in any tool's description or inputSchema.
    /// The env var is an internal measurement seam — leaking it into the MCP schema
    /// would expose implementation details to MCP clients.
    @Test func benchEpochEnvKeyNotInToolSchemas() throws {
        // Use empty environment to bypass vault/memory gating and check all tools.
        let tools = ToolProjection.tools(environment: [:])

        for tool in tools {
            #expect(
                !tool.description.contains(BenchClock.envKey),
                "tool \(tool.name) description must not mention \(BenchClock.envKey)"
            )
            // Encode the inputSchema to JSON text for substring search.
            let schemaText: String
            if let data = try? tool.inputSchema.encoded(),
               let s = String(data: data, encoding: .utf8) {
                schemaText = s
            } else {
                schemaText = ""
            }
            #expect(
                !schemaText.contains(BenchClock.envKey),
                "tool \(tool.name) inputSchema must not mention \(BenchClock.envKey)"
            )
        }
    }
}
