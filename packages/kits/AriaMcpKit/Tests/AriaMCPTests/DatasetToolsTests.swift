// DatasetToolsTests.swift
// AriaMcpKit
//
// Integration tests for the dataset MCP tool surface (MX-TAB-7b, Scope 3).
//
// Coverage:
//   - Tool projection: 3 dataset tools present, all carry .interface provenance.
//   - End-to-end: moot_file_dataset (inline rows) → moot_dataset_query →
//     moot_dataset_stats, verifying response headers and row counts.
//   - Cohesion lens dataset mode: moot_lens_cohesion with dataset_id returns
//     "dataset_cohesion:" header.
//   - Withdraw refusals: all three dataset-surfaced tools (query, stats, cohesion
//     lens) refuse a withdrawn handle with isError: true.
//   - Vault round-trip: export (scope=believed) → import into fresh estate →
//     recall dataset handle → decode DatasetHandleContent → query rows in B.
//   - Column name validation: SQL injection, leading digit, hyphen all throw
//     JSONRPCError before any DDL is emitted.
//   - csv_path security: directory, symlink-to-directory, and missing file all
//     throw JSONRPCError.
//   - Size cap constant: DatasetTools.csvPathSizeCapBytes == 100 MiB.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: each test case opens live in-memory estates and may touch
/// the filesystem (vault round-trip, csv_path checks) — same discipline as
/// LensToolsTests and VaultToolsTests.
@Suite("Dataset tools", .serialized)
struct DatasetToolsTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Extract the `isError: false` response body text from a tool result.
    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    /// Parse a "  key: value" line out of a multi-line response body.
    /// Trims leading whitespace before matching so indented response fields
    /// (e.g. "  id: <UUID>") are found without knowing the indent depth.
    private func extractValue(key: String, from body: String) -> String? {
        let prefix = "\(key): "
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Build a `moot_file_dataset` inline-rows argument object.
    ///
    /// - Parameters:
    ///   - name: Dataset name stored as the handle's room label.
    ///   - columns: Name + type pairs; type must be "text", "int", "float", or "bool".
    ///   - rows: Array of row dicts keyed by column name.
    ///   - location: Room location for the estate handle.
    private func datasetArgs(
        name: String,
        columns: [(name: String, type: String)],
        rows: [[String: JSONValue]],
        location: String
    ) -> [String: JSONValue] {
        let colArray = JSONValue.array(columns.map { col in
            JSONValue.object(["name": .string(col.name), "type": .string(col.type)])
        })
        let rowArray = JSONValue.array(rows.map { row in
            JSONValue.object(row)
        })
        return [
            "name":     .string(name),
            "columns":  colArray,
            "rows":     rowArray,
            "location": .string(location),
        ]
    }

    private func makeTempVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("datasettools-\(UUID().uuidString)", isDirectory: true)
    }

    /// Scan the response body for a "job_id: <UUID>" line and return the UUID string.
    private func extractJobID(from result: JSONValue) throws -> String {
        let body = try text(result)
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("job_id:") {
                return String(trimmed.dropFirst("job_id:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        struct NoJobID: Error {}
        throw NoJobID()
    }

    /// Poll `moot_vault_job` at 100 ms intervals until the job leaves the
    /// "running" state or 10 seconds elapse. Mirrors VaultToolsTests.waitForJob.
    private func waitForJob(id: String, via dispatcher: ToolDispatcher) async throws -> String {
        var statusText = ""
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms per poll
            let result = try await dispatcher.dispatch(
                name: "moot_vault_job",
                arguments: .object(["job_id": .string(id)]))
            statusText = try text(result)
            if !statusText.contains("status: running") { break }
        }
        return statusText
    }

    /// Export the vault and block until the async job reports "status: complete".
    private func runExportAndAwait(
        vault: URL, scope: String = "believed", via dispatcher: ToolDispatcher
    ) async throws {
        // `scope: believed` is required here because dataset handles are born
        // as unconfirmed drawers (the default export scope is `exportable`, which
        // would skip them — per CAND-032, the same fix applied in VaultToolsTests).
        let result = try await dispatcher.dispatch(
            name: "moot_vault_export",
            arguments: .object([
                "vaultPath": .string(vault.path),
                "scope":     .string(scope),
            ]))
        let jobID = try extractJobID(from: result)
        let status = try await waitForJob(id: jobID, via: dispatcher)
        #expect(status.contains("status: complete"), "Export job did not complete within 10 s")
    }

    // MARK: - Tool projection

    @Test func toolListContainsThreeDatasetTools() {
        let names = Set(ToolProjection.tools().map(\.name))
        #expect(names.contains("moot_file_dataset"))
        #expect(names.contains("moot_dataset_query"))
        #expect(names.contains("moot_dataset_stats"))
    }

    @Test func datasetToolsCarryInterfaceProvenance() {
        // Dataset tools are AI-client-facing CRUD operations (they carry an
        // optional estateID like all interface tools), so they carry the
        // .interface provenance per DatasetTools.swift design note.
        let datasetTools = ToolProjection.tools().filter {
            DatasetTools.isDatasetTool($0.name)
        }
        #expect(datasetTools.count == 3)
        for tool in datasetTools {
            #expect(tool.provenance == .interface,
                "\(tool.name) must carry .interface provenance")
        }
    }

    // MARK: - End-to-end: file → query → stats

    @Test func fileDatasetQueryStatsEndToEnd() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-e2e"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File a 3-row, 2-column dataset using inline rows.
        let fileArgs = datasetArgs(
            name: "fruit-scores",
            columns: [(name: "label", type: "text"), (name: "score", type: "int")],
            rows: [
                ["label": .string("apple"),  "score": .integer(95)],
                ["label": .string("banana"), "score": .integer(80)],
                ["label": .string("cherry"), "score": .integer(72)],
            ],
            location: "lab/produce"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset",
            arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        #expect(fileBody.hasPrefix("dataset_filed:"),
            "moot_file_dataset must return a dataset_filed: header; got: \(fileBody)")
        #expect(fileBody.contains("columns: 2"))
        #expect(fileBody.contains("rows: 3"))

        let datasetId = try #require(extractValue(key: "id", from: fileBody),
            "dataset_filed response must include an id: line")
        #expect(UUID(uuidString: datasetId) != nil,
            "dataset id must be a valid UUID; got: \(datasetId)")

        // Query: full scan, no predicates.
        let queryResult = try await dispatcher.dispatch(
            name: "moot_dataset_query",
            arguments: .object(["id": .string(datasetId)]))
        let queryBody = try text(queryResult)
        #expect(queryBody.hasPrefix("dataset_query:"),
            "moot_dataset_query must return a dataset_query: header; got: \(queryBody)")
        #expect(queryBody.contains("rows_returned: 3"))
        #expect(queryBody.contains("apple"))
        #expect(queryBody.contains("banana"))
        #expect(queryBody.contains("cherry"))

        // Stats: all columns.
        let statsResult = try await dispatcher.dispatch(
            name: "moot_dataset_stats",
            arguments: .object(["id": .string(datasetId)]))
        let statsBody = try text(statsResult)
        #expect(statsBody.hasPrefix("dataset_stats:"),
            "moot_dataset_stats must return a dataset_stats: header; got: \(statsBody)")
        #expect(statsBody.contains("label:"))
        #expect(statsBody.contains("score:"))
        // count: 3 appears in at least one column's stats block.
        #expect(statsBody.contains("count: 3"))
    }

    // MARK: - Cohesion lens dataset mode

    @Test func cohesionLensInDatasetModeReturnsDatasetHeader() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-lens"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs = datasetArgs(
            name: "lens-test",
            columns: [(name: "item", type: "text"), (name: "value", type: "int")],
            rows: [
                ["item": .string("a"), "value": .integer(1)],
                ["item": .string("b"), "value": .integer(2)],
                ["item": .string("c"), "value": .integer(3)],
            ],
            location: "lens-lab"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        let datasetId = try #require(extractValue(key: "id", from: fileBody))

        // moot_lens_cohesion with a dataset_id routes through the dataset mode,
        // which returns a "dataset_cohesion:" header (LensTools.swift §DatasetMode).
        let cohesionResult = try await dispatcher.dispatch(
            name: "moot_lens_cohesion",
            arguments: .object(["dataset_id": .string(datasetId)]))
        let cohesionBody = try text(cohesionResult)
        #expect(cohesionBody.contains("dataset_cohesion:"),
            "moot_lens_cohesion with dataset_id must return dataset_cohesion: header; got: \(cohesionBody)")
    }

    // MARK: - Withdraw refusals

    @Test func withdrawnHandleRefusedByQuery() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-wq"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs = datasetArgs(
            name: "doomed-q",
            columns: [(name: "x", type: "int")],
            rows: [["x": .integer(1)]],
            location: "lab"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        let datasetId = try #require(extractValue(key: "id", from: fileBody))
        let handleId  = try #require(extractValue(key: "handle_id", from: fileBody))

        // Withdraw the dataset handle via GLK — moves its State axis to .withdrawn.
        try await kit.withdraw(handle, WithdrawFrame(rowID: handleId, reason: "test-withdraw-q"))

        // moot_dataset_query must refuse with isError: true (not a transport throw).
        let queryResult = try await dispatcher.dispatch(
            name: "moot_dataset_query",
            arguments: .object(["id": .string(datasetId)]))
        let queryObj = try #require(queryResult.objectValue)
        #expect(queryObj["isError"]?.boolValue == true,
            "moot_dataset_query on a withdrawn handle must set isError: true")
    }

    @Test func withdrawnHandleRefusedByStats() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-ws"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs = datasetArgs(
            name: "doomed-s",
            columns: [(name: "y", type: "int")],
            rows: [["y": .integer(2)]],
            location: "lab"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        let datasetId = try #require(extractValue(key: "id", from: fileBody))
        let handleId  = try #require(extractValue(key: "handle_id", from: fileBody))

        try await kit.withdraw(handle, WithdrawFrame(rowID: handleId, reason: "test-withdraw-s"))

        let statsResult = try await dispatcher.dispatch(
            name: "moot_dataset_stats",
            arguments: .object(["id": .string(datasetId)]))
        let statsObj = try #require(statsResult.objectValue)
        #expect(statsObj["isError"]?.boolValue == true,
            "moot_dataset_stats on a withdrawn handle must set isError: true")
    }

    @Test func withdrawnHandleRefusedByCohesionLens() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-wc"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs = datasetArgs(
            name: "doomed-lens",
            columns: [(name: "z", type: "int")],
            rows: [["z": .integer(3)]],
            location: "lab"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        let datasetId = try #require(extractValue(key: "id", from: fileBody))
        let handleId  = try #require(extractValue(key: "handle_id", from: fileBody))

        try await kit.withdraw(handle, WithdrawFrame(rowID: handleId, reason: "test-withdraw-lens"))

        // moot_lens_cohesion in dataset mode must refuse a withdrawn handle with
        // isError: true. The refusal path goes: resolveDataset → resolveActiveDatasetHandle
        // → LocusKitError.withdrawnDatasetHandle → DatasetResolutionError.refusal.
        let cohesionResult = try await dispatcher.dispatch(
            name: "moot_lens_cohesion",
            arguments: .object(["dataset_id": .string(datasetId)]))
        let cohesionObj = try #require(cohesionResult.objectValue)
        #expect(cohesionObj["isError"]?.boolValue == true,
            "moot_lens_cohesion on a withdrawn handle must set isError: true")
    }

    // MARK: - Vault round-trip

    @Test func datasetRoundTripThroughVault() async throws {
        let kit = GeniusLocusKit()
        let handleA = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-vault-src"))
        let dispatcherA = ToolDispatcher(kit: kit, handle: handleA)

        // File a 3-row dataset in estate A.
        let fileArgs = datasetArgs(
            name: "roundtrip-dataset",
            columns: [(name: "fruit", type: "text"), (name: "rank", type: "int")],
            rows: [
                ["fruit": .string("apple"),  "rank": .integer(1)],
                ["fruit": .string("banana"), "rank": .integer(2)],
                ["fruit": .string("cherry"), "rank": .integer(3)],
            ],
            location: "vault-test"
        )
        let fileResult = try await dispatcherA.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        #expect(fileBody.contains("rows: 3"))

        // Export estate A's vault (scope: believed so the unconfirmed dataset handle
        // is included). VaultTools.exportDatasetCSVs writes a companion CSV at the
        // same relative path as the dataset note but with a .csv extension.
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try await runExportAndAwait(vault: vault, scope: "believed", via: dispatcherA)

        // Import the vault into a fresh estate B.
        let handleB = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-vault-dst"))
        let dispatcherB = ToolDispatcher(kit: kit, handle: handleB)
        let importLaunch = try await dispatcherB.dispatch(
            name: "moot_vault_import",
            arguments: .object(["vaultPath": .string(vault.path)]))
        let importJobID = try extractJobID(from: importLaunch)
        // VaultTools.importDatasetNotes runs inside the import Task after the
        // main vault bridge. Poll until the Task (including dataset import) finishes.
        let importStatus = try await waitForJob(id: importJobID, via: dispatcherB)
        #expect(importStatus.contains("status: complete"),
            "Vault import job must complete; got: \(importStatus)")

        // Recall from estate B and find the dataset handle drawer (contentKind == .dataset).
        // Dataset handles are born as unconfirmed, so filterChain: [.unconfirmed] surfaces them.
        // hydrationLevel: .full is REQUIRED here — .structured omits the content blob
        // (DrawerStore returns content == "" by design at the structured tier), so
        // DatasetHandleContent.decode would fail with "Unexpected end of file" at .structured.
        let drawers = try await kit.recall(
            handleB,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full))
        let datasetDrawers = drawers.filter { $0.contentKind == .dataset }
        let importedDrawer = try #require(datasetDrawers.first,
            "Vault round-trip must produce at least one dataset handle in estate B")

        // Decode the DatasetHandleContent from the drawer body (it is the JSON payload).
        let importedContent = try DatasetHandleContent.decode(from: importedDrawer.content)
        #expect(importedContent.rowCount == 3,
            "Imported DatasetHandleContent must report rowCount 3; got: \(importedContent.rowCount)")
        #expect(importedContent.columns.count == 2,
            "Imported DatasetHandleContent must have 2 columns; got: \(importedContent.columns.count)")

        // Query the re-imported dataset in estate B to confirm rows are present.
        let queryResult = try await dispatcherB.dispatch(
            name: "moot_dataset_query",
            arguments: .object(["id": .string(importedContent.datasetId.uuidString)]))
        let queryBody = try text(queryResult)
        #expect(queryBody.contains("rows_returned: 3"))
        #expect(queryBody.contains("apple"))
        #expect(queryBody.contains("banana"))
        #expect(queryBody.contains("cherry"))
    }

    // MARK: - Column name validation

    @Test func sqlInjectionColumnNameRejectedBeforeDDL() async throws {
        // Column identifiers must match [A-Za-z_][A-Za-z0-9_]*. A name
        // containing a semicolon or SQL metacharacter is rejected before any
        // DDL is emitted (no sanitize-and-continue path per DatasetTools.swift design).
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-colval-sql"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let badName = "name; DROP TABLE x --"
        let cols = JSONValue.array([
            JSONValue.object(["name": .string(badName), "type": .string("text")])
        ])
        let rows = JSONValue.array([
            JSONValue.object([badName: .string("bad")])
        ])
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("bad"),
                    "columns":  cols,
                    "rows":     rows,
                    "location": .string("lab"),
                ]))
        }
    }

    @Test func columnNameWithLeadingDigitRejected() async throws {
        // A column name whose first character is a digit fails the
        // [A-Za-z_][A-Za-z0-9_]* regex check before any DDL.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-colval-dig"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let cols = JSONValue.array([
            JSONValue.object(["name": .string("1bad"), "type": .string("text")])
        ])
        let rows = JSONValue.array([
            JSONValue.object(["1bad": .string("x")])
        ])
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("leaddigit"),
                    "columns":  cols,
                    "rows":     rows,
                    "location": .string("lab"),
                ]))
        }
    }

    @Test func columnNameWithHyphenRejected() async throws {
        // A hyphen is not in [A-Za-z0-9_] so "bad-col" is rejected.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-colval-hyp"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let cols = JSONValue.array([
            JSONValue.object(["name": .string("bad-col"), "type": .string("text")])
        ])
        let rows = JSONValue.array([
            JSONValue.object(["bad-col": .string("x")])
        ])
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("hyphen"),
                    "columns":  cols,
                    "rows":     rows,
                    "location": .string("lab"),
                ]))
        }
    }

    // MARK: - csv_path security checks

    @Test func csvPathToDirectoryIsRejected() async throws {
        // resolveCSVPath checks that the resolved path is a regular file —
        // a directory path is rejected before any parse attempt.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-csvdir"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let dirPath = FileManager.default.temporaryDirectory.path
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("bad"),
                    "csv_path": .string(dirPath),
                    "location": .string("lab"),
                ]))
        }
    }

    @Test func csvPathSymlinkToDirectoryIsRejected() async throws {
        // A symlink whose resolved target is a directory is rejected:
        // resolveCSVPath calls URL.resolvingSymlinksInPath() before the
        // FileAttributeType.typeRegular check, so the real type is tested.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-csvlink"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let target = FileManager.default.temporaryDirectory
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("bad"),
                    "csv_path": .string(link.path),
                    "location": .string("lab"),
                ]))
        }
    }

    @Test func csvPathMissingFileIsRejected() async throws {
        // A path that does not exist fails the "file exists" check
        // in resolveCSVPath before size or type checks are reached.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-csvmiss"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).csv").path
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("bad"),
                    "csv_path": .string(missingPath),
                    "location": .string("lab"),
                ]))
        }
    }

    // MARK: - Size cap constant

    @Test func csvPathSizeCapConstantIsHundredMiB() {
        // The constant is `internal` in DatasetTools — accessible via @testable import.
        #expect(DatasetTools.csvPathSizeCapBytes == 100 * 1_048_576,
            "csvPathSizeCapBytes must be exactly 100 MiB (104,857,600 bytes)")
    }

    // MARK: - MX-TAB-SEC-1 A1: import-root confinement

    @Test func csvPathOutsideImportRootRejected() async throws {
        // A1 (MX-TAB-SEC-1): after canonicalization the resolved path must lie
        // inside the allowed import root (home directory). A real regular CSV
        // file in the system temp directory (outside home) must be rejected with
        // a JSONRPCError naming the import-root violation.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a1-outside"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Create a real, valid CSV file outside the home directory.
        let outsidePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-a1-outside-\(UUID().uuidString).csv")
        try "name,score\napple,1\n".write(to: outsidePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsidePath) }

        await #expect(throws: JSONRPCError.self,
            "csv_path outside the import root must throw JSONRPCError") {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("outside"),
                    "csv_path": .string(outsidePath.path),
                    "location": .string("lab"),
                ]))
        }
    }

    @Test func csvPathSymlinkEscapingImportRootRejected() async throws {
        // A1 (MX-TAB-SEC-1): a symlink whose canonical target is OUTSIDE the
        // import root is rejected even if the symlink itself lives inside home.
        // Verifies the check operates on the canonicalized path, not the raw one.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a1-symesc"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Real CSV in temp (outside home).
        let outsideCSV = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-a1-target-\(UUID().uuidString).csv")
        try "col\n1\n".write(to: outsideCSV, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideCSV) }

        // Symlink inside home directory pointing at the outside file.
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let symlink = homeDir.appendingPathComponent(".ds-a1-link-\(UUID().uuidString).csv")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideCSV)
        defer { try? FileManager.default.removeItem(at: symlink) }

        // After resolveCSVPath resolves the symlink, the canonical path is
        // outside home — A1 must reject it.
        await #expect(throws: JSONRPCError.self,
            "symlink escaping import root must throw JSONRPCError after canonicalization") {
            _ = try await dispatcher.dispatch(
                name: "moot_file_dataset",
                arguments: .object([
                    "name":     .string("escape"),
                    "csv_path": .string(symlink.path),
                    "location": .string("lab"),
                ]))
        }
    }

    // MARK: - MX-TAB-SEC-1 A2: provenance basename redaction

    @Test func csvPathSourceDescriptionIsBasenameOnly() async throws {
        // A2 (MX-TAB-SEC-1): sourceDescription stored in the handle must be
        // "csv:<basename>" only — the full canonical path must not appear.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a2-basename"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // CSV must be inside the home directory to pass A1 confinement.
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let subdir = homeDir.appendingPathComponent(".ds-a2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: subdir) }

        let csvFile = subdir.appendingPathComponent("fruits.csv")
        try "name,score\napple,1\nbanana,2\n".write(to: csvFile, atomically: true, encoding: .utf8)

        let result = try await dispatcher.dispatch(
            name: "moot_file_dataset",
            arguments: .object([
                "name":     .string("a2-test"),
                "csv_path": .string(csvFile.path),
                "location": .string("lab/a2"),
            ]))
        let body = try text(result)
        // The response body contains "source: csv:<something>" — verify it exists
        // and contains only the basename (no directory separators after "csv:").
        let sourceLine = try #require(
            extractValue(key: "source", from: body),
            "response must contain a 'source:' line; got: \(body)")
        #expect(sourceLine.hasPrefix("csv:"),
            "source must start with 'csv:'; got: \(sourceLine)")
        let afterPrefix = sourceLine.dropFirst("csv:".count)
        #expect(!afterPrefix.contains("/"),
            "source must not contain path separators — got: \(sourceLine)")
        #expect(afterPrefix == "fruits.csv",
            "source basename must be the actual filename; got: \(sourceLine)")
    }

    // MARK: - MX-TAB-SEC-1 A3: MCP-layer column identifier validation

    @Test func parseLayerBadColumnInWhereRejectedWithInvalidParams() async throws {
        // A3 (MX-TAB-SEC-1): parse_where_predicate / parseWherePredicate validates
        // column identifiers at the MCP layer before they reach SQL generation.
        // A hostile col value like "name; DROP TABLE x" must be rejected with
        // JSONRPCError (not silently truncated by the backend).
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a3-where"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // First create a dataset to query against.
        let fileArgs = datasetArgs(
            name: "a3-where",
            columns: [(name: "name", type: "text")],
            rows: [["name": .string("alice")]],
            location: "lab/a3"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        let datasetId = try #require(extractValue(key: "id", from: fileBody))

        // Inject a bad column name in the where clause.
        // NOTE: the where argument is a SINGLE JSON object (a simple condition),
        // not an array. Arrays in the where field are treated as "absent predicate"
        // by parseWherePredicate — only object or JSON-string inputs are parsed.
        // Compound conditions use {"and": [...]} or {"or": [...]} wrappers.
        let badWhere = JSONValue.object([
            "col": .string("name; DROP TABLE x"),
            "op":  .string("eq"),
            "val": .string("alice"),
        ])
        await #expect(throws: JSONRPCError.self,
            "bad column identifier in where 'col' must throw JSONRPCError at parse layer") {
            _ = try await dispatcher.dispatch(
                name: "moot_dataset_query",
                arguments: .object([
                    "id":    .string(datasetId),
                    "where": badWhere,
                ]))
        }
    }

    @Test func parseLayerBadColumnInOrderByRejectedWithInvalidParams() async throws {
        // A3 (MX-TAB-SEC-1): same two-layer guard applies in parseOrderBy.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a3-order"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs = datasetArgs(
            name: "a3-order",
            columns: [(name: "score", type: "int")],
            rows: [["score": .integer(1)]],
            location: "lab/a3o"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        let datasetId = try #require(extractValue(key: "id", from: fileBody))

        let badOrderBy = JSONValue.array([
            JSONValue.object([
                "col": .string("score; DROP TABLE x"),
                "dir": .string("asc"),
            ])
        ])
        await #expect(throws: JSONRPCError.self,
            "bad column identifier in order_by 'col' must throw JSONRPCError at parse layer") {
            _ = try await dispatcher.dispatch(
                name: "moot_dataset_query",
                arguments: .object([
                    "id":       .string(datasetId),
                    "order_by": badOrderBy,
                ]))
        }
    }

    // MARK: - MX-TAB-SEC-1 A4: vault export sensitivity gate

    @Test func restrictedDatasetHandleProducesNoCsvOnExport() async throws {
        // A4 (MX-TAB-SEC-1): a dataset handle with sensitivity=restricted must
        // never produce a companion .csv in the vault.
        //
        // Note on observable behavior: the vault bridge (VaultExportScope /
        // The export trust boundary already excludes restricted-sensitivity drawers from the
        // note export by default. This means bridge.export does not write the
        // .md note either, so A4's loop body never fires for this path.
        //
        // A4 provides defense-in-depth: if a restricted note were ever present
        // in the vault (future scope change, direct vault write, or import path),
        // A4 suppresses the companion CSV. This test verifies the observable
        // safe outcome: no .csv is produced for a restricted dataset handle under
        // any current export scope.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a4-restricted"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // File a dataset with sensitivity=restricted.
        var restrictedArgs = datasetArgs(
            name: "sensitive-data",
            columns: [(name: "secret", type: "text")],
            rows: [["secret": .string("classified")]],
            location: "vault/secure"
        )
        restrictedArgs["sensitivity"] = .string("restricted")

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(restrictedArgs))
        let fileBody = try text(fileResult)
        #expect(fileBody.hasPrefix("dataset_filed:"),
            "moot_file_dataset must accept a restricted dataset; got: \(fileBody)")

        // Export vault (scope: believed includes unconfirmed drawers by
        // confirmation state — sensitivity gating is independent of this).
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try await runExportAndAwait(vault: vault, scope: "believed", via: dispatcher)

        // No .csv must appear — whether suppressed by A4 directly (when the
        // note is present) or by the vault bridge's existing sensitivity filter
        // (when the note is absent). Either way, CSV data must not leave the estate.
        let csvFiles = try FileManager.default.subpathsOfDirectory(
            atPath: vault.path).filter { $0.hasSuffix(".csv") }
        #expect(csvFiles.isEmpty,
            "restricted dataset handle must not produce a companion .csv; found: \(csvFiles)")
    }

    @Test func normalSensitivityDatasetExportsBothNoteAndCsv() async throws {
        // A4 (MX-TAB-SEC-1): confirms the gate does NOT block normal datasets.
        // A normal (default) dataset must produce both a .md note and a .csv companion.
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "ds-a4-normal"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let fileArgs = datasetArgs(
            name: "normal-data",
            columns: [(name: "item", type: "text")],
            rows: [["item": .string("apple")]],
            location: "vault/normal"
        )
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_dataset", arguments: .object(fileArgs))
        let fileBody = try text(fileResult)
        #expect(fileBody.hasPrefix("dataset_filed:"))

        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try await runExportAndAwait(vault: vault, scope: "believed", via: dispatcher)

        let csvFiles = try FileManager.default.subpathsOfDirectory(
            atPath: vault.path).filter { $0.hasSuffix(".csv") }
        let mdFiles = try FileManager.default.subpathsOfDirectory(
            atPath: vault.path).filter { $0.hasSuffix(".md") }

        #expect(!csvFiles.isEmpty,
            "normal dataset handle must produce a companion .csv in the vault")
        #expect(!mdFiles.isEmpty,
            "normal dataset handle note (.md) must be present in the vault")
    }
}
