import AriaMCPWire
import CognitionKit
import Foundation

/// Shared typed request for the two selected-v2 cognition directories.
/// `verbose` gates a terse/verbose split: terse (default) returns the
/// minimal name+description row; verbose returns the full schema row.
public struct AriaV2CognitionCatalogRequest: Sendable, Equatable {
    public let verbose: Bool
    public let estateID: UUID?

    public init(arguments: JSONValue) throws {
        let decoder = try AriaV2ArgumentDecoder(
            arguments, allowedKeys: ["verbose", "estate_id"])
        verbose = try decoder.optionalBoolean("verbose") ?? false
        estateID = try decoder.optionalUUID("estate_id")
    }
}

/// Direct structured projection of the live cognition registries. This layer
/// reads descriptors only; it never invokes the v1 text/JSON recipe runner.
public struct AriaV2CognitionCatalogService: Sendable {
    public static let lensesToolName = "moot_list_lenses"
    public static let recipesToolName = "moot_list_recipes"

    public let estateID: UUID
    public let callableToolNames: Set<String>
    public let buildID: String
    public let capabilityDigest: String

    public init(
        estateID: UUID,
        callableToolNames: Set<String>,
        buildID: String,
        capabilityDigest: String
    ) {
        self.estateID = estateID
        self.callableToolNames = callableToolNames
        self.buildID = buildID
        self.capabilityDigest = capabilityDigest
    }

    public func lenses(_ request: AriaV2CognitionCatalogRequest) throws -> JSONValue {
        try validate(request)
        let filteredTools = (RecipeTools.tools() + LensTools.tools())
            .filter { callableToolNames.contains($0.name) }
        if request.verbose {
            // Verbose: include input_schema and output_schema for each tool.
            // output_schema comes from the effective registry (ToolProjection),
            // not from LensTools/RecipeTools direct instances. LensTools
            // instances carry outputSchema: nil; RecipeTools instances vary —
            // the five recall tools declare ToolProjection.recallResultsOutputSchema(),
            // while the rest carry nil. Using ToolProjection for all tools
            // ensures port parity: the v2 catalog's declared schemas are the
            // single source of truth, regardless of per-tool defaults.
            let outputSchemaByName = Self.buildOutputSchemaLookup()
            let fullTools = filteredTools.map { tool -> JSONValue in
                var obj: [String: JSONValue] = [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                ]
                if let outputSchema = outputSchemaByName[tool.name] {
                    obj["output_schema"] = outputSchema
                }
                return .object(obj)
            }
            let nameList = filteredTools.map(\.name).joined(separator: ", ")
            return envelope(
                tool: Self.lensesToolName,
                data: .object(["tools": .array(fullTools)]),
                text: "Listed \(filteredTools.count) callable cognition tools (full schema). Tools: \(nameList)")
        } else {
            // Terse: name and description only. input_schema omitted.
            let terseTools = filteredTools.map { tool in
                JSONValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                ])
            }
            let base = envelope(
                tool: Self.lensesToolName,
                data: .object(["tools": .array(terseTools)]),
                text: "Listed \(filteredTools.count) callable cognition tools.")
            return AriaV2Envelope.applyHint(
                "(terse — pass verbose:true for the full schema row)", to: base)
        }
    }

    public func recipes(_ request: AriaV2CognitionCatalogRequest) throws -> JSONValue {
        try validate(request)
        let allRecipes = RecipeCatalog.all
        if request.verbose {
            // Verbose: include required_capabilities for each recipe.
            let fullRecipes = allRecipes.map { recipe in
                JSONValue.object([
                    "name": .string(recipe.name),
                    "version": .string(recipe.version),
                    "description": .string(recipe.description),
                    "required_capabilities": .array(
                        recipe.requiredCapabilities.map { .string("\($0)") }),
                ])
            }
            // Compact text lists capability requirements per recipe so the
            // "requires: " lines satisfy the v1-parity assertion in tests.
            let capsLines = allRecipes.compactMap { recipe -> String? in
                guard !recipe.requiredCapabilities.isEmpty else { return nil }
                let caps = recipe.requiredCapabilities.map { "\($0)" }.joined(separator: ", ")
                return "\(recipe.name) requires: \(caps)"
            }
            let summaryText: String
            if capsLines.isEmpty {
                summaryText = "Listed \(allRecipes.count) recipe(s)."
            } else {
                summaryText = "Listed \(allRecipes.count) recipe(s).\n" + capsLines.joined(separator: "\n")
            }
            return envelope(
                tool: Self.recipesToolName,
                data: .object(["recipes": .array(fullRecipes)]),
                text: summaryText)
        } else {
            // Terse: name, version, description only. required_capabilities omitted.
            let terseRecipes = allRecipes.map { recipe in
                JSONValue.object([
                    "name": .string(recipe.name),
                    "version": .string(recipe.version),
                    "description": .string(recipe.description),
                ])
            }
            let base = envelope(
                tool: Self.recipesToolName,
                data: .object(["recipes": .array(terseRecipes)]),
                text: "Listed \(allRecipes.count) recipe(s).")
            return AriaV2Envelope.applyHint(
                "(terse — pass verbose:true for the full schema row)", to: base)
        }
    }

    /// Build a name→outputSchema lookup from the effective registry's projected
    /// tools. `ToolProjection.tools()` returns projectedTools from the selected
    /// catalog, which carry outputSchema per operation. LensTools instances carry
    /// outputSchema: nil; RecipeTools instances vary (the five recall tools set
    /// ToolProjection.recallResultsOutputSchema(), the rest carry nil). Using
    /// ToolProjection is the correct path because it reads from the authoritative
    /// v2 catalog declarations, keeping both ports in sync.
    private static func buildOutputSchemaLookup() -> [String: JSONValue] {
        Dictionary(
            ToolProjection.tools().compactMap { tool -> (String, JSONValue)? in
                guard let schema = tool.outputSchema else { return nil }
                return (tool.name, schema)
            },
            uniquingKeysWith: { first, _ in first })
    }

    private func validate(_ request: AriaV2CognitionCatalogRequest) throws {
        guard request.estateID == nil || request.estateID == estateID else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "The requested estate is not available to this caller.")
        }
    }

    private func envelope(tool: String, data: JSONValue, text: String) -> JSONValue {
        AriaV2Envelope.success(
            tool: tool,
            effect: .read,
            data: data,
            meta: [
                "build_id": .string(buildID),
                "capability_digest": .string(capabilityDigest),
                "completeness": .string("incomplete"),
            ],
            compactText: text)
    }
}
