import AriaMCPWire
import CognitionKit
import Foundation

/// Shared typed request for the two selected-v2 cognition directories.
/// `verbose` is accepted for source compatibility; v2 returns the complete
/// structured projection instead of a prose-only terse/verbose rendering.
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
        _ = request.verbose
        let tools = (RecipeTools.tools() + LensTools.tools())
            .filter { callableToolNames.contains($0.name) }
            .map { tool in
                JSONValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                ])
            }
        return envelope(
            tool: Self.lensesToolName,
            data: .object(["tools": .array(tools)]),
            text: "Listed \(tools.count) callable cognition tools.")
    }

    public func recipes(_ request: AriaV2CognitionCatalogRequest) throws -> JSONValue {
        try validate(request)
        _ = request.verbose
        let recipes = RecipeCatalog.all.map { recipe in
            JSONValue.object([
                "name": .string(recipe.name),
                "version": .string(recipe.version),
                "description": .string(recipe.description),
                "required_capabilities": .array(
                    recipe.requiredCapabilities.map { .string("\($0)") }),
            ])
        }
        return envelope(
            tool: Self.recipesToolName,
            data: .object(["recipes": .array(recipes)]),
            text: "Listed \(recipes.count) CognitionKit recipe records.")
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
