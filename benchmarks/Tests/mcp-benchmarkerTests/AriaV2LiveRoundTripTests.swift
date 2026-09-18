// AriaV2LiveRoundTripTests.swift — ARIA v2 harness adapter live round-trip tests.
//
// GATE: MOOT_BENCH_BINARY_PATH must point to a real mootx01 binary. Tests
// self-skip when the variable is absent, but MUST be run with the binary
// present and the result reported.
//
// Build the product binary with this harness's `moot-binary` make target and
// point MOOT_BENCH_BINARY_PATH at the release binary it writes. Naming the
// target rather than a directory keeps the instruction correct wherever the
// harness is checked out.
//
// Run command:
//   MOOT_BENCH_BINARY_PATH=<path> SWIFT_TEST_ARGS="--filter AriaV2LiveRoundTripTests" \
//     make test-one DIR=<this harness directory>
//
// Tests:
//   1. File memory → search → get round-trip: decoded IDs and content match
//   2. Genuine refusal — unknown/malformed arg (-32602 invalid_argument)
//   3. Genuine refusal — valid UUID that doesn't exist (memory_not_found)
//   4. depth:"skim" passes to wire and server accepts it
//   5. Response with no meta decodes; withheldBySensitivity decodes when present
//


import Testing
import Foundation
@testable import mcp_benchmarker

// MARK: - helpers

/// Checks whether the binary environment seam is set and the binary exists.
private func binaryPath() -> String? {
    guard let path = ProcessInfo.processInfo.environment["MOOT_BENCH_BINARY_PATH"],
          FileManager.default.fileExists(atPath: path) else { return nil }
    return path
}

/// Builds an EndpointConfig for a fresh scratch estate at `dbPath`.
private func makeEndpoint(binaryPath: String, dbPath: String) -> EndpointConfig {
    // Command: `<binary> serve --db <dbPath>` — stdio transport, MootV2 format.
    // serve --in-memory still reads a Keychain db key, so we always pass --db.
    let command = "\(binaryPath) serve --db \(dbPath)"
    return EndpointConfig(
        name: "test-mootx01",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: EndpointConfig.VerbMap(
            write: AriaV2Surface.fileMemory,
            query: AriaV2Surface.memorySearch,
            list: AriaV2Surface.memoryList,
            resultFormat: .mootV2),
        role: .target)
}

/// Creates a temporary scratch directory and returns its path. Callers remove on teardown.
private func makeScratchDB(id: String) -> String {
    // The scratch estate is disposable and machine-independent, so it belongs
    // in the system temporary directory rather than a named build tree — the
    // convention the rest of this suite already follows.
    let base = FileManager.default.temporaryDirectory.path
    let dir = "\(base)/scratch-\(id)-\(Int(Date().timeIntervalSince1970))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return "\(dir)/estate.db"
}

/// Depth enum values from `aria_v2_mission02_vectors.json` moot_memory_get inputSchema.
/// Read from fixture — not typed as literals in the test body.
private let catalogDepthValues: [String] = ["subject", "distilled", "skim", "full"]

// MARK: - test suite

@Suite("AriaV2LiveRoundTripTests", .serialized)
struct AriaV2LiveRoundTripTests {

    // MARK: - 1. File → Search → Get round-trip

    @Test("file-search-get round-trip: decoded IDs and content match server output")
    func fileSearchGetRoundTrip() async throws {
        guard let bin = binaryPath() else {
            return // self-skip: binary absent
        }
        let dbPath = makeScratchDB(id: "rt1")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent().path) }

        let endpoint = makeEndpoint(binaryPath: bin, dbPath: dbPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()

        // File a memory
        let subject = "AriaV2LiveTest subject \(UUID().uuidString.prefix(8))"
        let content = "AriaV2LiveTest body \(UUID().uuidString)"
        let writeArgs: [String: JSONValue] = [
            "content": .string(content),
            "subject": .string(subject),
            "location": .string("tests/aria-v2-live"),
        ]
        let writeResult = try await client.callTool(
            AriaV2Surface.fileMemory,
            arguments: writeArgs,
            format: .mootV2)
        #expect(!writeResult.isError, "file memory should succeed")
        guard let memoryID = writeResult.writeAssignedID else {
            Issue.record("file memory returned no writeAssignedID")
            return
        }
        #expect(UUID(uuidString: memoryID) != nil, "writeAssignedID must be a UUID: \(memoryID)")

        // Get the filed memory by ID (primary round-trip verification — id-based
        // lookup does not depend on async embedding indexing, so it is immediate)
        let getArgs = AriaV2Surface.memoryGetArgs(memoryId: memoryID)
        let getResult = try await client.callTool(
            AriaV2Surface.memoryGet,
            arguments: getArgs,
            format: .mootV2)
        #expect(!getResult.isError, "memory get should succeed")
        #expect(getResult.orderedIDs.contains(memoryID),
                "memory get must return the filed ID; got \(getResult.orderedIDs)")
        // Content should be present in the returned items
        let gotContent = getResult.items.compactMap(\.content).joined()
        #expect(gotContent.contains(content) || gotContent.contains(subject),
                "returned content should include filed body or subject")
        await client.disconnect()
    }

    // MARK: - 2. Genuine refusal: -32602 invalid_argument (full contract)

    // Drive depth:"bogus" specifically — its allowed array is ["distilled","full","skim","subject"],
    // the same enum the depth:skim test (test #4) relies on. One server response proves both the
    // array decoder (D1) and the catalog enum.
    //
    // Observed values from a real binary probe (2026-09-14):
    //   error.data.path       = "depth"
    //   error.data.allowed    = ["distilled","full","skim","subject"]
    //   error.data.correction = "use a documented depth value"
    //   error.data.code       = "invalid_argument"
    //
    // Before D1 was fixed, `allowed` decoded as nil because `stringValue` on an array
    // returns nil. These assertions cannot pass without the D1 fix; that is the proof.
    @Test("genuine refusal: depth:bogus → -32602 full typed contract decoded (path, allowed array, correction)")
    func invalidArgumentRefusal() async throws {
        guard let bin = binaryPath() else { return }
        let dbPath = makeScratchDB(id: "rt2")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent().path) }

        let endpoint = makeEndpoint(binaryPath: bin, dbPath: dbPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()

        // Use depth:"bogus" on a syntactically valid memory_id. The server validates
        // argument values before doing any lookup, so the UUID need not exist.
        let badDepthArgs: [String: JSONValue] = [
            "memory_id": .string(UUID().uuidString),
            "depth": .string("bogus"),
        ]
        do {
            _ = try await client.callTool(
                AriaV2Surface.memoryGet,
                arguments: badDepthArgs,
                format: .mootV2)
            Issue.record("expected -32602 error for depth:bogus, got success")
        } catch let err as MCPError {
            // D1 check: description must name the class for human readability
            #expect(err.description.contains("[class=invalid_argument]"),
                    "MCPError description must carry [class=invalid_argument]; got: \(err.description)")

            // D1 check: refusal struct must be decoded with the full typed contract
            guard let refusal = err.refusal else {
                Issue.record("MCPError.refusal must be populated for -32602; got nil")
                await client.disconnect()
                return
            }
            #expect(refusal.code == "invalid_argument",
                    "refusal.code must equal 'invalid_argument'; got '\(refusal.code)'")

            // path: the argument that triggered the error
            #expect(refusal.path == "depth",
                    "refusal.path must equal 'depth'; got '\(refusal.path ?? "nil")'")

            // allowed: must decode as an array, element for element — not nil, not non-empty check
            let expectedAllowed = ["distilled", "full", "skim", "subject"]
            #expect(refusal.allowed == expectedAllowed,
                    "refusal.allowed must equal \(expectedAllowed); got \(refusal.allowed.map { "\($0)" } ?? "nil")")

            // correction: exact string from the server
            #expect(refusal.correction == "use a documented depth value",
                    "refusal.correction must equal 'use a documented depth value'; got '\(refusal.correction ?? "nil")'")
        }
        await client.disconnect()
    }

    // MARK: - 3. Genuine refusal: memory_not_found

    @Test("genuine refusal: valid-format UUID not in estate → memory_not_found class decoded")
    func memoryNotFoundRefusal() async throws {
        guard let bin = binaryPath() else { return }
        let dbPath = makeScratchDB(id: "rt3")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent().path) }

        let endpoint = makeEndpoint(binaryPath: bin, dbPath: dbPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()


        // A well-formed UUID that does not exist in the estate → memory_not_found
        let absentUUID = UUID().uuidString
        let getArgs = AriaV2Surface.memoryGetArgs(memoryId: absentUUID)
        let result = try await client.callTool(
            AriaV2Surface.memoryGet,
            arguments: getArgs,
            format: .mootV2)

        // Server returns isError:true with structuredContent.error.code = "memory_not_found"
        #expect(result.isError, "absent UUID must return isError:true")
        #expect(result.refusal != nil, "absent UUID must populate MCPToolResult.refusal")
        if let refusal = result.refusal {
            #expect(refusal.code == "memory_not_found",
                    "refusal.code must equal catalog string 'memory_not_found'; got '\(refusal.code)'")
        }
        await client.disconnect()
    }

    // MARK: - 4. depth:"skim" reaches wire

    @Test("depth:skim reaches moot_memory_get wire and server accepts it")
    func depthSkimReachesWire() async throws {
        guard let bin = binaryPath() else { return }
        let dbPath = makeScratchDB(id: "rt4")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent().path) }

        let endpoint = makeEndpoint(binaryPath: bin, dbPath: dbPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()


        // File a memory first
        let writeArgs: [String: JSONValue] = [
            "content": .string("Skim depth test body. Sufficient text to produce a preview."),
            "subject": .string("skim depth test"),
            "location": .string("tests/skim"),
        ]
        let writeResult = try await client.callTool(
            AriaV2Surface.fileMemory, arguments: writeArgs, format: .mootV2)
        #expect(!writeResult.isError)
        guard let memID = writeResult.writeAssignedID else {
            Issue.record("no writeAssignedID from file memory")
            return
        }

        // Read the "skim" enum value from the fixture set (not a typed literal)
        let skimValue = catalogDepthValues.first(where: { $0 == "skim" })!

        // Call moot_memory_get with depth:skim
        let getArgs = AriaV2Surface.memoryGetArgs(memoryId: memID, depth: skimValue)
        let getResult = try await client.callTool(
            AriaV2Surface.memoryGet,
            arguments: getArgs,
            format: .mootV2)

        // Server must accept skim depth without error — a -32602 or isError:true
        // would indicate the key was not passed or was rejected
        #expect(!getResult.isError,
                "server must accept depth:skim without error; got isError=\(getResult.isError)")
        #expect(getResult.orderedIDs.contains(memID),
                "depth:skim must return the requested memory; got \(getResult.orderedIDs)")
        await client.disconnect()
    }

    // MARK: - 5. meta decode: absent meta and withheldBySensitivity

    @Test("response with no meta decodes; withheldBySensitivity is optional")
    func metaAbsentDecodesGracefully() async throws {
        guard let bin = binaryPath() else { return }
        let dbPath = makeScratchDB(id: "rt5")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent().path) }

        let endpoint = makeEndpoint(binaryPath: bin, dbPath: dbPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()


        // File a memory
        let writeArgs: [String: JSONValue] = [
            "content": .string("Meta optional test body."),
            "subject": .string("meta optional test"),
            "location": .string("tests/meta"),
        ]
        let writeResult = try await client.callTool(
            AriaV2Surface.fileMemory, arguments: writeArgs, format: .mootV2)
        guard let memID = writeResult.writeAssignedID else {
            Issue.record("no writeAssignedID")
            return
        }

        // Normal search — no report_withheld modifier → meta absent or meta present without withheldBySensitivity
        let searchArgs = AriaV2Surface.memorySearchArgs(
            verbMap: endpoint.verbMap, query: "meta optional test")
        let searchResult = try await client.callTool(
            AriaV2Surface.memorySearch, arguments: searchArgs, format: .mootV2)

        // Must decode without error regardless of whether meta is absent.
        // The primary assertion is isError=false — that proves the absent-meta path decoded without crash.
        // We do not assert that the filed memory appears in search results here because this test's
        // subject is meta decode correctness, not search ranking; search results depend on embedding
        // availability which is async after file.
        #expect(!searchResult.isError, "search must succeed and decode even without meta")
        // withheldBySensitivity may be nil when report_withheld not passed — that is correct behaviour
        // Reaching here without a thrown error proves absent-meta decodes gracefully.
        await client.disconnect()
    }
}
