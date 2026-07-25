import Foundation
import PersistenceKit

/// Stable on-disk GLK estate format identity.
///
/// This is deliberately independent of package releases and the additive
/// composite schema version. Historical migration capsules use it to declare
/// their source and target floors; the current runtime uses it only to refuse
/// an estate that has not yet reached the format it knows how to serve.
public struct EstateFormatVersion: Sendable, Codable, Hashable, Comparable,
    CustomStringConvertible
{
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let v1_0 = EstateFormatVersion(major: 1, minor: 0)
    public static let v1_1 = EstateFormatVersion(major: 1, minor: 1)
    public static let current = v1_1

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// Current-runtime format errors. Concrete migration availability is owned by
/// the optional migration catalog, not by this core module.
public enum EstateFormatError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The estate predates the stable format stamp or was created by an SDK
    /// that did not opt into the migration catalog.
    case migrationRequired(current: EstateFormatVersion)
    /// The estate carries a stable format other than the one this runtime can
    /// serve. An upgrade-capable host must run its compiled migration chain.
    case unsupported(found: EstateFormatVersion, current: EstateFormatVersion)
    /// The format schema was registered but its singleton row could not be
    /// read or decoded. This is corruption/backend failure, never "unstamped".
    case storage(reason: String)

    public var description: String {
        switch self {
        case let .migrationRequired(current):
            return "estate migration required before GLK \(current) can open semantic substores"
        case let .unsupported(found, current):
            return "estate format \(found) is not directly supported by GLK \(current)"
        case let .storage(reason):
            return "estate format storage failure: \(reason)"
        }
    }
}

/// The only historical-migration seam retained by the current runtime: one
/// stable format row and current-format validation. The table contains no
/// migration state and no knowledge of legacy layouts.
public actor EstateFormatStore {
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "GLKEstateFormat",
        version: 1,
        tables: [
            TableDeclaration(
                name: "glk_estate_format",
                columns: [
                    .text("id", nullable: false),
                    .int("major", nullable: false),
                    .int("minor", nullable: false),
                    .timestamp("updated_at", nullable: false),
                ],
                primaryKey: ["id"]
            )
        ]
    )

    private static let singletonID = "estate-format"
    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Read without creating the format table. Missing-table and missing-row
    /// both mean an unstamped estate, which the core must refuse.
    public func readIfPresent() async throws -> EstateFormatVersion? {
        let registered: Int
        do { registered = try await storage.currentSchemaVersion(for: "GLKEstateFormat") }
        catch { throw EstateFormatError.storage(reason: String(describing: error)) }
        let rows: [StorageRow]
        do { rows = try await storage.rowStore.query(
            table: "glk_estate_format",
            where: .eq(
                Column(table: "glk_estate_format", name: "id"),
                .text(Self.singletonID)
            ),
            orderBy: [], limit: 1, offset: nil)
        } catch {
            if registered == 0 { return nil }
            throw EstateFormatError.storage(reason: String(describing: error))
        }
        guard let row = rows.first else {
            if registered == 0 { return nil }
            throw EstateFormatError.storage(reason: "registered singleton row is missing")
        }
        guard
            case let .int(major)? = row["major"],
            case let .int(minor)? = row["minor"]
        else { throw EstateFormatError.storage(reason: "singleton row is malformed") }
        return EstateFormatVersion(major: Int(major), minor: Int(minor))
    }

    /// Stamp a format only after a fresh provision or a verified migration.
    public func stamp(_ version: EstateFormatVersion, now: Date) async throws {
        try await storage.migrate(to: Self.schemaDeclaration)
        _ = try await storage.rowStore.upsert(
            table: "glk_estate_format",
            values: [
                "id": .text(Self.singletonID),
                "major": .int(Int64(version.major)),
                "minor": .int(Int64(version.minor)),
                "updated_at": .timestamp(now),
            ],
            conflictColumns: ["id"]
        )
    }

    public func requireCurrent() async throws {
        guard let found = try await readIfPresent() else {
            throw EstateFormatError.migrationRequired(current: .current)
        }
        guard found == .current else {
            throw EstateFormatError.unsupported(found: found, current: .current)
        }
    }
}
