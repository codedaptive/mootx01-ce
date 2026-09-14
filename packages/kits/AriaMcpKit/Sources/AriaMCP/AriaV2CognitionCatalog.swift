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
        let filteredTools = AriaV2SelectedCatalog.descriptors
            .filter { $0.isLensLaneMember && callableToolNames.contains($0.publicName) }
            .sorted { $0.lensLaneOrder! < $1.lensLaneOrder! }
        let catalogByName = Self.buildCatalogLookup()
        if request.verbose {
            // Verbose: include input_schema and output_schema for each tool.
            // All three of description, input_schema, and output_schema come from
            // the v2 catalog projection (ToolProjection).
            let fullTools = try filteredTools.map { tool -> JSONValue in
                guard let catalog = catalogByName[tool.publicName] else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.internalError,
                        message: "Cognition catalog entry missing for lens/recipe tool \"\(tool.publicName)\"; registry may be out of sync.")
                }
                var obj: [String: JSONValue] = [
                    "name": .string(tool.publicName),
                    "description": .string(catalog.description),
                    "input_schema": catalog.inputSchema,
                ]
                if let outputSchema = catalog.outputSchema {
                    obj["output_schema"] = outputSchema
                }
                return .object(obj)
            }
            let nameList = filteredTools.map(\.publicName).joined(separator: ", ")
            return envelope(
                tool: Self.lensesToolName,
                data: .object(["tools": .array(fullTools)]),
                text: "Listed \(filteredTools.count) callable cognition tools (full schema). Tools: \(nameList)")
        } else {
            // Terse: name and description only. input_schema omitted.
            // Description comes from the v2 catalog projection.
            let terseTools = try filteredTools.map { tool -> JSONValue in
                guard let catalog = catalogByName[tool.publicName] else {
                    throw JSONRPCError(
                        code: JSONRPCErrorCode.internalError,
                        message: "Cognition catalog entry missing for lens/recipe tool \"\(tool.publicName)\"; registry may be out of sync.")
                }
                return JSONValue.object([
                    "name": .string(tool.publicName),
                    "description": .string(catalog.description),
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

    /// Build a name→ProjectedTool lookup from the v2 catalog projection.
    /// `ToolProjection.tools()` returns projectedTools from the selected catalog,
    /// which carry the authoritative description, inputSchema, and outputSchema
    /// per operation. This keeps the lens lane in sync with the tools/list surface.
    private static func buildCatalogLookup() -> [String: ProjectedTool] {
        Dictionary(
            ToolProjection.tools().map { ($0.name, $0) },
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
