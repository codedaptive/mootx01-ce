import XCTest
import Testing
import Foundation
@testable import mcp_benchmarker

final class ConfigTests: XCTestCase {

    /// Writes JSON to a temp file and returns its URL.
    private func writeTempConfig(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// A complete, valid config: external MCP source → MOOTx01 target.
    private let validJSON = """
    {
      "source": {
        "name": "external-source",
        "transport": { "stdio": { "command": "external-mcp" } },
        "verbMap": { "write": "store", "query": "search", "list": "list_all" },
        "role": "source"
      },
      "target": {
        "name": "mootx01",
        "transport": { "stdio": { "command": "aria-mcp" } },
        "verbMap": { "write": "capture", "query": "recall", "list": null },
        "role": "target"
      }
    }
    """

    // 1. A valid config loads; both source and target endpoints are present.
    func testValidConfigLoads() throws {
        let url = try writeTempConfig(validJSON)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = try BenchmarkerConfig.load(from: url)
        XCTAssertEqual(cfg.source.name, "external-source")
        XCTAssertEqual(cfg.target.name, "mootx01")
        XCTAssertEqual(cfg.source.verbMap.write, "store")
        XCTAssertEqual(cfg.target.verbMap.query, "recall")
        XCTAssertNil(cfg.target.verbMap.list)
    }

    // 2. A config missing verbMap.write throws ConfigError.missingField.
    func testMissingWriteVerbThrows() throws {
        let bad = """
        {
          "source": {
            "name": "s", "transport": { "stdio": { "command": "x" } },
            "verbMap": { "query": "search", "list": "list_all" }, "role": "source"
          },
          "target": {
            "name": "t", "transport": { "stdio": { "command": "y" } },
            "verbMap": { "write": "capture", "query": "recall", "list": null }, "role": "target"
          }
        }
        """
        let url = try writeTempConfig(bad)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BenchmarkerConfig.load(from: url)) { error in
            guard case ConfigError.missingField(let field) = error else {
                return XCTFail("expected ConfigError.missingField, got \(error)")
            }
            XCTAssertEqual(field, "verbMap.write")
        }
    }

    // 3. Source and target endpoints are distinct values.
    func testSourceAndTargetDistinct() throws {
        let url = try writeTempConfig(validJSON)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = try BenchmarkerConfig.load(from: url)
        XCTAssertNotEqual(cfg.source.name, cfg.target.name)
        XCTAssertNotEqual(cfg.source.role, cfg.target.role)
    }
}

// MARK: - Extended verbMap config fields (importer + export)
// These exercise the importer's endpoint-config fields.

struct ImporterConfigTests {

    private func loadVerbMap(_ verbMapJSON: String) throws -> EndpointConfig.VerbMap {
        let json = """
        {
          "source": {
            "name": "s", "transport": { "stdio": { "command": "x" } },
            "verbMap": \(verbMapJSON), "role": "source"
          },
          "target": {
            "name": "t", "transport": { "stdio": { "command": "y" } },
            "verbMap": { "write": "w", "query": "q", "list": null }, "role": "target"
          }
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try BenchmarkerConfig.load(from: url).source.verbMap
    }

    @Test("New importer fields default for a terse verbMap")
    func importerDefaults() throws {
        let vm = try loadVerbMap(#"{ "write": "w", "query": "q", "list": "l" }"#)
        #expect(vm.fetch == nil)
        #expect(vm.fetchIDArg == "drawer_id")
        #expect(vm.fetchContentKey == "content")
        #expect(vm.listLimitArg == "limit")
        #expect(vm.listOffsetArg == "offset")
        #expect(vm.listPageSize == 100)
    }

    @Test("External MCP source verbMap decodes fetch + pagination fields")
    func externalSourceImporterFields() throws {
        let vm = try loadVerbMap("""
        {
          "write": "external_add_item",
          "query": "external_search",
          "list": "external_list_items",
          "fetch": "external_get_item",
          "fetchIDArg": "drawer_id",
          "fetchContentKey": "content",
          "listPageSize": 100,
          "resultFormat": { "kind": "jsonObjects", "idKey": "drawer_id", "contentKey": "content_preview" }
        }
        """)
        #expect(vm.fetch == "external_get_item")
        #expect(vm.fetchContentKey == "content")
        #expect(vm.listPageSize == 100)
    }
}
