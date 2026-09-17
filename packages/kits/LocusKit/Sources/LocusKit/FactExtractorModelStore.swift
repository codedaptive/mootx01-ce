import Foundation
import PersistenceKit

/// One `fact_extractor_models` registry row. The row is deliberately model-
/// runtime neutral; provider targets translate it into their contract spec.
public struct FactExtractorModelRow: Sendable, Equatable, Codable {
    public let recipeID: String
    public let providerID: String
    public let modelID: String
    public let modelVersion: String
    public let schemaVersion: String
    public let extractorKind: String
    public let maximumInputCharacters: Int
    public let maximumFactsPerSource: Int
    public let isActive: Bool

    public init(
        recipeID: String, providerID: String, modelID: String,
        modelVersion: String, schemaVersion: String, extractorKind: String,
        maximumInputCharacters: Int, maximumFactsPerSource: Int,
        isActive: Bool = false
    ) {
        self.recipeID = recipeID
        self.providerID = providerID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.schemaVersion = schemaVersion
        self.extractorKind = extractorKind
        self.maximumInputCharacters = maximumInputCharacters
        self.maximumFactsPerSource = maximumFactsPerSource
        self.isActive = isActive
    }
}

/// The sole writer for the fact-extractor registry and activation debt.
public actor FactExtractorModelStore {
    let storage: any Storage

    public init(storage: any Storage) { self.storage = storage }

    public func active() async throws -> FactExtractorModelRow? {
        let rows = try await storage.rowStore.query(
            table: "fact_extractor_models",
            where: .eq(Column(table: "fact_extractor_models", name: "is_active"), .int(1)),
            orderBy: [OrderClause(column: Column(table: "fact_extractor_models", name: "recipe_id"), direction: .ascending)],
            limit: 1, offset: nil)
        return try rows.first.map(Self.row(from:))
    }

    public func all() async throws -> [FactExtractorModelRow] {
        try await storage.rowStore.query(
            table: "fact_extractor_models", where: .isTrue,
            orderBy: [OrderClause(column: Column(table: "fact_extractor_models", name: "recipe_id"), direction: .ascending)],
            limit: nil, offset: nil).map { try Self.row(from: $0) }
    }

    public func upsert(_ row: FactExtractorModelRow) async throws {
        try Self.validate(row)
        _ = try await storage.transaction(isolation: .serializable) { txn in
            let existing = try await txn.rowStore.query(
                table: "fact_extractor_models",
                where: .eq(Column(table: "fact_extractor_models", name: "recipe_id"), .text(row.recipeID)),
                orderBy: [], limit: 1, offset: nil).first.map(Self.row(from:))
            let invalidatesDebt = existing.map { previous in
                previous.providerID != row.providerID
                    || previous.modelID != row.modelID
                    || previous.modelVersion != row.modelVersion
                    || previous.schemaVersion != row.schemaVersion
                    || previous.isActive != row.isActive
            } ?? row.isActive

            if row.isActive {
                _ = try await txn.rowStore.update(
                    table: "fact_extractor_models", values: ["is_active": .int(0)],
                    where: .eq(Column(table: "fact_extractor_models", name: "is_active"), .int(1)))
            }
            _ = try await txn.rowStore.upsert(
                table: "fact_extractor_models",
                values: [
                "recipe_id": .text(row.recipeID),
                "provider_id": .text(row.providerID),
                "model_id": .text(row.modelID),
                "model_version": .text(row.modelVersion),
                "schema_version": .text(row.schemaVersion),
                "extractor_kind": .text(row.extractorKind),
                "maximum_input_characters": .int(Int64(row.maximumInputCharacters)),
                "maximum_facts_per_source": .int(Int64(row.maximumFactsPerSource)),
                "is_active": .int(row.isActive ? 1 : 0),
                "ext": .null,
                ],
                conflictColumns: ["recipe_id"])
            return invalidatesDebt ? try await Self.clearExtractionDebt(in: txn.rowStore) : 0
        }
    }

    /// Activating a recipe clears bits 28 and 29 on every carrier (a rejection
    /// under the previous recipe is owed again under the new one). Old KGFacts
    /// stay auditable while the duty deterministically supersedes their projection.
    @discardableResult
    public func activate(recipeID: String) async throws -> Int {
        try await storage.transaction(isolation: .serializable) { txn in
            let target = try await txn.rowStore.query(
                table: "fact_extractor_models",
                where: .eq(Column(table: "fact_extractor_models", name: "recipe_id"), .text(recipeID)),
                orderBy: [], limit: 1, offset: nil, columns: ["recipe_id"])
            guard !target.isEmpty else {
                throw LocusKitError.invalidContent(
                    "fact_extractor_models has no row for recipe_id \(recipeID)")
            }
            _ = try await txn.rowStore.update(
                table: "fact_extractor_models", values: ["is_active": .int(0)],
                where: .eq(Column(table: "fact_extractor_models", name: "is_active"), .int(1)))
            _ = try await txn.rowStore.update(
                table: "fact_extractor_models", values: ["is_active": .int(1)],
                where: .eq(Column(table: "fact_extractor_models", name: "recipe_id"), .text(recipeID)))

            return try await Self.clearExtractionDebt(in: txn.rowStore)
        }
    }

    private static func clearExtractionDebt(in rowStore: any RowStore) async throws -> Int {
        let carriers = try await rowStore.query(
            table: "drawers",
            where: .bitmaskAll(Column(table: "drawers", name: "operationalBitmap"),
                               mask: DrawerFeatureFlags.factsExtracted.rawValue),
            orderBy: [], limit: nil, offset: nil, columns: ["id", "operationalBitmap"])
        var cleared = 0
        for carrier in carriers {
            guard case let .text(id) = carrier["id"] ?? .null else { continue }
            let bitmap = Self.bitmap(carrier["operationalBitmap"])
            cleared += try await rowStore.update(
                table: "drawers",
                values: ["operationalBitmap": .bitmap(
                    bitmap & ~(DrawerFeatureFlags.factsExtracted.rawValue
                               | DrawerFeatureFlags.factsRejected.rawValue))],
                where: .eq(Column(table: "drawers", name: "id"), .text(id)))
        }
        return cleared
    }

    private static func validate(_ row: FactExtractorModelRow) throws {
        let required = [row.recipeID, row.providerID, row.modelID, row.modelVersion,
                        row.schemaVersion, row.extractorKind]
        guard required.allSatisfy({ !$0.isEmpty }),
              row.maximumInputCharacters > 0, row.maximumFactsPerSource > 0 else {
            throw LocusKitError.invalidContent("invalid FactExtractorModelRow")
        }
    }

    private static func bitmap(_ value: TypedValue?) -> Int64 {
        switch value {
        case .bitmap(let value), .int(let value): value
        default: 0
        }
    }

    private static func row(from row: StorageRow) throws -> FactExtractorModelRow {
        func text(_ key: String) throws -> String {
            guard case let .text(value) = row[key] ?? .null else {
                throw LocusKitError.corruptStoredValue(
                    table: "fact_extractor_models", column: key, storedText: "(null)")
            }
            return value
        }
        func int(_ key: String) throws -> Int {
            guard case let .int(value) = row[key] ?? .null else {
                throw LocusKitError.corruptStoredValue(
                    table: "fact_extractor_models", column: key, storedText: "(null)")
            }
            return Int(value)
        }
        return FactExtractorModelRow(
            recipeID: try text("recipe_id"), providerID: try text("provider_id"),
            modelID: try text("model_id"), modelVersion: try text("model_version"),
            schemaVersion: try text("schema_version"), extractorKind: try text("extractor_kind"),
            maximumInputCharacters: try int("maximum_input_characters"),
            maximumFactsPerSource: try int("maximum_facts_per_source"),
            isActive: try int("is_active") != 0)
    }
}
