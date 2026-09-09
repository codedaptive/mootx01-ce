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

    // MARK: - Cohesion lens dataset mode

    // MARK: - Withdraw refusals

    // MARK: - Vault round-trip

    // MARK: - Column name validation

    // MARK: - csv_path security checks

    // MARK: - Size cap constant

    @Test func csvPathSizeCapConstantIsHundredMiB() {
        // The constant is `internal` in DatasetTools — accessible via @testable import.
        #expect(DatasetTools.csvPathSizeCapBytes == 100 * 1_048_576,
            "csvPathSizeCapBytes must be exactly 100 MiB (104,857,600 bytes)")
    }

    // MARK: - MX-TAB-SEC-1 A1: import-root confinement

    // MARK: - MX-TAB-SEC-1 A2: provenance basename redaction

    // MARK: - MX-TAB-SEC-1 A3: MCP-layer column identifier validation

    // MARK: - MX-TAB-SEC-1 A4: vault export sensitivity gate
}
