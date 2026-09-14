import Foundation
import Testing
import AriaMCPWire
@testable import AriaMCP

/// Regenerates aria_v2_mission02_vectors.json from the live Swift catalog.
///
/// Gate: set REGENERATE_FIXTURE=1 in the environment. Ordinary suite runs
/// exit immediately — this test has no assertions and produces no output
/// when the gate is absent.
///
/// The generator is a reconciler, not a from-scratch writer. It loads the
/// existing fixture with JSONValue.parse, overwrites the live-derivable fields
/// on every row, carries help.example and help.nearest_alternative forward
/// unchanged, applies the three renames (updating each example's inner "name"
/// string), and writes the file back with all object keys sorted so the output
/// is deterministic across runs. The generator iterates the live registry and
/// rebuilds every row in place — including moot_memory_recall_transcript, which
/// has been in the fixture since its row was added and is carried forward like
/// any other row. Nothing is appended.
///
/// B1: Renames the three dead tool names inside every catalog_variants.tools
/// array, using the same mapping listed under "Rename mapping" below. Without
/// this pass the variants would silently retain the old names after the
/// catalog.operations rows are updated.
///
/// B2: Removes moot_memory_recall_transcript from
/// negative_catalog_assertions.absent and from absent_reason, because both
/// the fixture and the live catalog now carry that operation and the negative
/// assertion is false.
///
/// The generator also writes base_full_feature_roster.expected_tool_count as
/// a derived field equal to the operation count from the rebuilt operations
/// list.
///
/// Live sources:
///   ToolProjection.tools(environment: [:])          -> description, inputSchema, outputSchema
///   AriaV2SelectedCatalog.registry(environment: [:])  -> identity, effect, availability, help
///
/// Rename mapping (dead fixture name -> live name):
///   moot_confirm_migration -> moot_migration_confirm
///   moot_run_migration     -> moot_migration_run
///   moot_federated_search  -> moot_federated_recall
///
/// Run via:
///   REGENERATE_FIXTURE=1 make test-one DIR=packages/kits/AriaMcpKit SWIFT_TEST_ARGS="--filter FixtureRegeneratorTests"
@Suite("FixtureRegenerator")
struct FixtureRegeneratorTests {

    @Test func regenerateAriaV2Mission02Fixture() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_FIXTURE"] == "1" else {
            return
        }

        // Locate the fixture from this source file's compile-time path.
        let fixturePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Tests/AriaMCPTests
            .deletingLastPathComponent()   // .../Tests
            .appendingPathComponent("Conformance/aria_v2_mission02_vectors.json")

        // Parse the existing fixture.
        let existingData = try Data(contentsOf: fixturePath)
        guard case .object(var root) = try JSONValue.parse(existingData) else {
            Issue.record("Fixture root is not a JSON object")
            return
        }
        guard case .object(var catalog) = root["catalog"] else {
            Issue.record("catalog key missing or not an object")
            return
        }
        guard case .array(let existingOps) = catalog["operations"] else {
            Issue.record("operations key missing or not an array")
            return
        }

        // Build lookup: existing fixture row by its current name
        // (the fixture may carry dead names for the three renamed operations).
        var fixtureByName: [String: [String: JSONValue]] = [:]
        for op in existingOps {
            if case .object(let obj) = op,
               case .string(let name) = obj["name"] {
                fixtureByName[name] = obj
            }
        }

        // Rename mapping: dead fixture name -> live public name.
        let renameMap: [String: String] = [
            "moot_confirm_migration": "moot_migration_confirm",
            "moot_run_migration":     "moot_migration_run",
            "moot_federated_search":  "moot_federated_recall",
        ]
        // Reverse: live name -> dead fixture name (for lookup in fixtureByName).
        let reverseRename: [String: String] = .init(
            uniqueKeysWithValues: renameMap.map { ($1, $0) }
        )

        // Live catalog data (vault enabled by default with empty environment).
        let registry = AriaV2SelectedCatalog.registry(environment: [:])
        let tools = ToolProjection.tools(environment: [:])
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        // Build the updated operations list.
        // registry.operations is already sorted alphabetically by publicName.
        var updatedOps: [[String: JSONValue]] = []

        for descriptor in registry.operations {
            let liveName = descriptor.publicName

            // Find existing fixture row: try live name first, then reverse-rename.
            let deadName = reverseRename[liveName]
            let existingRow: [String: JSONValue]?
            if let row = fixtureByName[liveName] {
                existingRow = row
            } else if let dead = deadName, let row = fixtureByName[dead] {
                existingRow = row
            } else {
                existingRow = nil
            }

            // Projected tool supplies description, inputSchema, and outputSchema.
            let tool = toolsByName[liveName]
            let description  = tool?.description ?? descriptor.help.description
            let inputSchema  = tool?.inputSchema  ?? descriptor.inputSchema
            let outputSchema = tool?.outputSchema ?? descriptor.projection.outputSchema

            // accepted_keys: property names of the live inputSchema, sorted.
            let acceptedKeys = inputSchemaPropertyNames(inputSchema)

            // availability.all_of: sorted required capability raw-values.
            let allOf: [JSONValue] = descriptor.availability.requiredCapabilities
                .map(\.rawValue)
                .sorted()
                .map { .string($0) }

            // Carry help.example and help.nearest_alternative from the existing row.
            var helpExample: JSONValue
            var helpNearest: JSONValue

            if let existing = existingRow,
               case .object(let helpObj) = existing["help"] {
                helpExample = helpObj["example"] ?? .null
                helpNearest = helpObj["nearest_alternative"] ?? .null

                // For renamed rows: update the inner "name" string in help.example.
                // The arguments are left unchanged.
                if deadName != nil,
                   case .object(var exObj) = helpExample {
                    exObj["name"] = .string(liveName)
                    helpExample = .object(exObj)
                }
            } else {
                // New row (no existing fixture entry): construct a placeholder example
                // with one "example" string per required key from the live inputSchema.
                let required = inputSchemaRequiredKeys(inputSchema)
                var args: [String: JSONValue] = [:]
                for key in required {
                    args[key] = .string("example")
                }
                helpExample = .object([
                    "name":      .string(liveName),
                    "arguments": .object(args),
                ])
                helpNearest = .null
            }

            let row: [String: JSONValue] = [
                "id":           .string(descriptor.identity.rawValue),
                "name":         .string(liveName),
                "description":  .string(description),
                "help": .object([
                    "intent":              .string(descriptor.help.description),
                    "example":             helpExample,
                    "nearest_alternative": helpNearest,
                ]),
                "effect":        .string(descriptor.effect.rawValue),
                "availability":  .object(["all_of": .array(allOf)]),
                "accepted_keys": .array(acceptedKeys.map { .string($0) }),
                "inputSchema":   inputSchema,
                "outputSchema":  outputSchema,
            ]
            updatedOps.append(row)
        }

        // Update the expected_tool_count in the header to reflect the new total.
        if case .object(var roster) = catalog["base_full_feature_roster"] {
            roster["expected_tool_count"] = .integer(Int64(updatedOps.count))
            catalog["base_full_feature_roster"] = .object(roster)
        }

        catalog["operations"] = .array(updatedOps.map { .object($0) })

        // B1: Rename dead tool names in catalog_variants.tools arrays.
        // The rename mapping mirrors the three renames applied to catalog.operations
        // above: dead fixture names → live ARIA v2 names.
        let toolRenames: [String: String] = [
            "moot_federated_search":  "moot_federated_recall",
            "moot_run_migration":     "moot_migration_run",
            "moot_confirm_migration": "moot_migration_confirm",
        ]
        if case .array(let variants) = catalog["catalog_variants"] {
            let updatedVariants: [JSONValue] = variants.map { variant in
                guard case .object(var variantObj) = variant,
                      case .array(let tools) = variantObj["tools"] else {
                    return variant
                }
                let updatedTools: [JSONValue] = tools.map { tool in
                    guard case .string(let name) = tool,
                          let liveName = toolRenames[name] else {
                        return tool
                    }
                    return .string(liveName)
                }
                variantObj["tools"] = .array(updatedTools)
                return .object(variantObj)
            }
            catalog["catalog_variants"] = .array(updatedVariants)
        }

        // B2: Remove moot_memory_recall_transcript from negative_catalog_assertions.
        // The fixture now carries this operation in catalog.operations and the live
        // catalog includes it; the negative assertion is false and is removed.
        if case .object(var negAssert) = root["negative_catalog_assertions"] {
            if case .array(let absentArr) = negAssert["absent"] {
                negAssert["absent"] = .array(absentArr.filter {
                    if case .string(let s) = $0, s == "moot_memory_recall_transcript" {
                        return false
                    }
                    return true
                })
            }
            if case .object(var absentReason) = negAssert["absent_reason"] {
                absentReason.removeValue(forKey: "moot_memory_recall_transcript")
                negAssert["absent_reason"] = .object(absentReason)
            }
            root["negative_catalog_assertions"] = .object(negAssert)
        }

        root["catalog"] = .object(catalog)

        // Serialize with all object keys sorted for a deterministic byte sequence.
        let serialized = sortedJSON(.object(root), indent: 0) + "\n"

        try serialized.write(to: fixturePath, atomically: true, encoding: .utf8)

        print(
            "Regenerated \(fixturePath.lastPathComponent): \(updatedOps.count) operations."
        )
    }

    // MARK: - Schema helpers

    /// Returns the names of the properties in an inputSchema object, sorted.
    private func inputSchemaPropertyNames(_ schema: JSONValue) -> [String] {
        guard case .object(let obj) = schema,
              case .object(let props) = obj["properties"] else { return [] }
        return props.keys.sorted()
    }

    /// Returns the required key names from an inputSchema's "required" array,
    /// preserving the order in which they appear in the schema.
    private func inputSchemaRequiredKeys(_ schema: JSONValue) -> [String] {
        guard case .object(let obj) = schema,
              case .array(let req) = obj["required"] else { return [] }
        return req.compactMap {
            if case .string(let s) = $0 { return s } else { return nil }
        }
    }

    // MARK: - Sorted-key JSON serializer

    /// Serializes a JSONValue tree with all object keys sorted alphabetically.
    /// Arrays preserve element order. Indentation is 2 spaces per level.
    ///
    /// Sorting object keys will reorder keys inside rows that are otherwise
    /// unchanged — that is expected and the price of reproducible output.
    private func sortedJSON(_ value: JSONValue, indent: Int) -> String {
        let pad   = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)

        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .integer(let i):
            return "\(i)"
        case .double(let d):
            // Whole doubles serialize without a decimal point.
            if d.truncatingRemainder(dividingBy: 1) == 0,
               d.isFinite,
               d >= Double(Int64.min),
               d <= Double(Int64.max) {
                return "\(Int64(d))"
            }
            return "\(d)"
        case .string(let s):
            return "\"\(jsonEscape(s))\""
        case .array(let arr):
            if arr.isEmpty { return "[]" }
            let items = arr.map { inner + sortedJSON($0, indent: indent + 2) }
            return "[\n" + items.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let pairs = dict.keys.sorted().map { key in
                "\(inner)\"\(jsonEscape(key))\": \(sortedJSON(dict[key]!, indent: indent + 2))"
            }
            return "{\n" + pairs.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// Escapes a Swift string for embedding in a JSON string literal.
    private func jsonEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out += String(scalar)
                }
            }
        }
        return out
    }
}
