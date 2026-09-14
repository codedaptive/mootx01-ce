import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

/// Dispatch-path coverage for eight ARIA v2 operations that were only exercised
/// at the typed service layer before this suite.  Each test calls
/// `ToolDispatcher.dispatch(name:arguments:)` — the production dispatcher —
/// rather than the typed service directly.
///
/// Every happy-path test asserts a payload value that would change if the
/// handler were swapped for a stub returning empty success; `isError == false`
/// alone is never the only assertion.
///
/// Migration coverage uses the selected v2 catalog names
/// `moot_migration_run` and `moot_migration_confirm`.
@Suite("ARIA v2 diagnostics and orchestration dispatch coverage", .serialized)
struct AriaV2DiagnosticsDispatchCoverageTests {

    // MARK: - Harness

    /// Creates a fresh in-memory estate and a live ToolDispatcher backed by it.
    /// Pattern matches FdcReclassifyTests.makeDispatcher (serverIdentity variant).
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "diag-dispatch-coverage-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle, serverIdentity: "diag-coverage"), kit, handle)
    }

    /// Extracts the typed data map from a v2 envelope response.
    private func data(_ result: JSONValue) -> [String: JSONValue]? {
        result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    // MARK: - moot_connection_map

    /// Files two memories and links them, then proves the connection_map handler
    /// returns the edge rather than an empty stub response.
    @Test("moot_connection_map dispatch path returns a populated edge list")
    func connectionMapDispatchYieldsEdges() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Capture two memories so there is a graph edge to return.
        let a = try await kit.capture(handle, CaptureFrame(
            content: "connection map source node",
            channel: .typed,
            room: "connectivity",
            latticeAnchor: .udc("004"),
            addedBy: "dispatch-coverage",
            embeddingModelID: "test-model-v1",
            subject: "conn-src"))
        let b = try await kit.capture(handle, CaptureFrame(
            content: "connection map target node",
            channel: .typed,
            room: "connectivity",
            latticeAnchor: .udc("004"),
            addedBy: "dispatch-coverage",
            embeddingModelID: "test-model-v1",
            subject: "conn-tgt"))

        _ = try await dispatcher.dispatch(name: "moot_link_memories", arguments: .object([
            "from_id": .string(a.id),
            "to_id": .string(b.id),
            "relationship": .string("references"),
        ]))

        let result = try await dispatcher.dispatch(name: "moot_connection_map", arguments: .object([
            "memory_id": .string(a.id),
        ]))
        #expect(result.objectValue?["isError"] == .bool(false))
        // A stub returning empty success would have an absent or empty edges list.
        let edges = try #require(data(result)?["edges"]?.arrayValue)
        #expect(!edges.isEmpty)
    }

    // MARK: - moot_dataset_stats

    /// Files a single-column dataset, then proves the stats handler returns the
    /// correct dataset_id and a non-nil stats map.
    @Test("moot_dataset_stats dispatch path returns per-column statistics for a filed dataset")
    func datasetStatsDispatchYieldsStats() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // File a minimal dataset so we have a real dataset_id to query.
        let filed = try await dispatcher.dispatch(name: "moot_file_dataset", arguments: .object([
            "name": .string("coverage-scores"),
            "location": .string("test"),
            "columns": .array([.object(["name": .string("score"), "type": .string("int")])]),
            "rows": .array([.object(["score": .integer(42)])]),
        ]))
        let filedData = try #require(
            filed.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        let datasetID = try #require(filedData["dataset_id"]?.stringValue)

        let result = try await dispatcher.dispatch(name: "moot_dataset_stats", arguments: .object([
            "dataset_id": .string(datasetID),
        ]))
        #expect(result.objectValue?["isError"] == .bool(false))
        // The echoed dataset_id must match what we filed.
        // A stub returning empty success would have no dataset_id in data.
        #expect(data(result)?["dataset_id"] == .string(datasetID))
        #expect(data(result)?["stats"]?.objectValue != nil)
    }

    // MARK: - moot_fact_timeline
    //
    // GATE DISCRIMINATION TEST: this is the test used to prove gate
    // discrimination.  Change "timeline-coverage" in the subject assertion to
    // any other string, run the suite — this test fails.  Restore the string
    // and the suite is green.

    /// Files a fact with a known subject, then proves the timeline handler
    /// returns that exact fact rather than an empty stub response.
    @Test("moot_fact_timeline dispatch path returns facts matching the requested subject")
    func factTimelineDispatchYieldsMatchingFacts() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // File a fact so the timeline is non-empty for this subject.
        _ = try await dispatcher.dispatch(name: "moot_file_fact", arguments: .object([
            "subject": .string("timeline-coverage"),
            "predicate": .string("is"),
            "object": .string("verified"),
        ]))

        let result = try await dispatcher.dispatch(name: "moot_fact_timeline", arguments: .object([
            "subject": .string("timeline-coverage"),
        ]))
        #expect(result.objectValue?["isError"] == .bool(false))
        // A stub returning empty success would have an empty facts list.
        let facts = try #require(data(result)?["facts"]?.arrayValue)
        #expect(!facts.isEmpty)
        // The returned fact must carry the exact subject we filed.
        // Changing "timeline-coverage" here to any other string causes this test to fail,
        // proving the assertion discriminates between real handler output and a stub.
        #expect(facts[0].objectValue?["subject"] == .string("timeline-coverage"))
    }

    // MARK: - moot_hunt_contradictions

    /// Proves the contradiction hunt handler returns an analysis reference for
    /// an empty estate.  An empty-success stub would omit the analysis_ref key.
    @Test("moot_hunt_contradictions dispatch path returns an analysis reference token")
    func huntContradictionsDispatchYieldsAnalysisRef() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Empty estate: no contradictions, but the handler still returns an
        // estate-specific analysis_ref and an empty candidates array.
        let storeBefore = try await kit.topologyChangeSignature(for: handle)
        let result = try await dispatcher.dispatch(
            name: "moot_hunt_contradictions", arguments: .object([:]))
        #expect(result.objectValue?["isError"] == .bool(false))
        // A stub returning empty success would have no analysis_ref in data.
        let analysisRef = try #require(data(result)?["analysis_ref"]?.stringValue)
        #expect(!analysisRef.isEmpty)
        let storeAfter = try await kit.topologyChangeSignature(for: handle)
        #expect(storeAfter == storeBefore,
                "moot_hunt_contradictions is read-only; store changed from \(storeBefore) to \(storeAfter)")
    }

    // MARK: - moot_review_tunnel

    /// Proves the review_tunnel dispatch route is wired by calling it with a
    /// tunnel_id that does not exist.  The lower layer catches the look-up
    /// failure and returns a structured refusal (isError == true) rather than
    /// throwing, so the test validates both the dispatch path and the refusal
    /// code.
    @Test("moot_review_tunnel dispatch path returns a mutation_unavailable refusal for an unknown tunnel")
    func reviewTunnelDispatchYieldsStructuredRefusalForUnknownTunnel() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // A UUID that has never been registered as a tunnel.  The review handler
        // catches the lower-kit error and wraps it in the unavailable refusal.
        let result = try await dispatcher.dispatch(name: "moot_review_tunnel", arguments: .object([
            "tunnel_id": .string(UUID().uuidString),
            "decision": .string("endorse"),
        ]))
        // A stub returning empty success would have isError == false.
        #expect(result.objectValue?["isError"] == .bool(true))
        // The specific error code distinguishes this from a generic failure.
        let code = try #require(
            result.objectValue?["structuredContent"]?.objectValue?["error"]?
                .objectValue?["code"]?.stringValue)
        #expect(code == "mutation_unavailable")
    }

    // MARK: - moot_timing_report

    /// Proves the timing_report dispatch route is wired and returns all three
    /// required keys.  A fresh empty estate has zero watermark advancement so
    /// since_ms must be zero.
    @Test("moot_timing_report dispatch path returns timing metrics with required keys")
    func timingReportDispatchYieldsTimingData() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(name: "moot_timing_report", arguments: .object([:]))
        #expect(result.objectValue?["isError"] == .bool(false))
        // A stub returning empty success would have an absent or empty data map.
        let d = try #require(data(result))
        #expect(d["since_ms"] != nil)
        #expect(d["watermark_ms"] != nil)
        #expect(d["truncated"] != nil)
        // A fresh empty estate has never advanced its watermark.
        #expect(d["since_ms"] == .integer(0))
    }

    // MARK: - moot_migration_run

    /// Proves the moot_migration_run dispatch route is wired through the v2
    /// catalog.  The tool name in structuredContent must match the operation name
    /// regardless of whether the migration itself succeeds or returns a refusal.
    ///
    @Test("moot_migration_run dispatch path is wired through the v2 catalog")
    func migrationRunDispatchIsWiredThroughV2Catalog() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        do {
            let result = try await dispatcher.dispatch(name: "moot_migration_run", arguments: .object([
                "corpusName": .string("coverage-corpus"),
                "entries": .array([
                    .object(["id": .string("e1"), "content": .string("migration coverage entry")]),
                ]),
                "plans": .array([
                    .object([
                        "name": .string("plan-a"),
                        "room": .string("Testing"),
                        "latticeCode": .string("000"),
                        "embeddingModelID": .string("test-model-v1"),
                    ]),
                ]),
            ]))
            // The tool name in the envelope identifies the exact operation.
            // A stub for a different handler or a methodNotFound stub would
            // carry a different (or absent) tool name.
            let tool = result.objectValue?["structuredContent"]?.objectValue?["tool"]?.stringValue
            #expect(tool == "moot_migration_run")
            // When the operation succeeds, winner_branch_id must be present.
            if result.objectValue?["isError"] == .bool(false) {
                #expect(data(result)?["winner_branch_id"]?.stringValue != nil)
            }
            // A structured refusal (isError == true) is also acceptable; it still
            // proves the route reached the orchestration handler.
        } catch let rpcError as JSONRPCError {
            // A domain-level JSONRPCError means the handler was reached.
            // methodNotFound would indicate the route is NOT wired.
            #expect(rpcError.code != JSONRPCErrorCode.methodNotFound)
        }
    }

    // MARK: - moot_migration_confirm

    /// Proves the moot_migration_confirm dispatch route is wired by calling it
    /// without the required winner_branch_id argument.  The argument decoder must
    /// throw JSONRPCError before reaching the lower provider.
    ///
    @Test("moot_migration_confirm dispatch path rejects missing winner_branch_id with invalidParams")
    func migrationConfirmDispatchThrowsOnMissingRequiredArg() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // winner_branch_id is required.  The decoder must throw JSONRPCError
        // with code invalidParams (-32602) before reaching the orchestration provider.
        // Asserting the specific error code discriminates against two failure modes
        // that #expect(throws: JSONRPCError.self) would pass silently:
        //   1. methodNotFound — the route was dropped from the v2 catalog entirely.
        //   2. A stub returning success — would not throw at all.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_migration_confirm", arguments: .object([:]))
            Issue.record("missing winner_branch_id must throw JSONRPCError invalidParams")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "moot_migration_confirm must produce -32602 invalidParams for missing winner_branch_id; got code: \(error.code)")
        }
    }
}
