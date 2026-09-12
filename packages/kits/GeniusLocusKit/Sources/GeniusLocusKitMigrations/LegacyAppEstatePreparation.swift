#if GLK_MIGRATION_APP_CONTAINER_TO_CATALOG

import Foundation

/// The pre-open coordination point for a pre-catalog Apple app estate.
///
/// Both the embedded Apple owner and the resident daemon call this type before
/// constructing storage for the catalog's default record. The filesystem and
/// Keychain mechanics remain in `AppContainerLayoutMigration`; this wrapper
/// turns its conflict outcome into a fail-closed error so a caller cannot
/// accidentally continue into an empty catalog estate.
public struct LegacyAppEstatePreparation: Sendable {

    public typealias KeyRelocator = @Sendable (URL, URL) throws -> Bool

    /// A conflict requires a person to select the default estate. Neither
    /// layout is changed and the catalog record must not be opened.
    public enum Error: Swift.Error, Sendable, Equatable {
        case conflictingDefaultEstates(legacy: URL, catalog: URL)
    }

    /// The container-level Application Support directory containing the
    /// legacy `mootx01/mootx01.sqlite` folder.
    public let applicationSupportDirectory: URL

    private let relocateKey: KeyRelocator

    /// Construct the preparation step.
    ///
    /// Production uses the shared estate-key relocation. Tests inject an
    /// isolated key store so no temporary estate reaches the login Keychain.
    public init(
        applicationSupportDirectory: URL,
        relocateKey: @escaping KeyRelocator = {
            try EstateOpenPosture.relocateKey(from: $0, to: $1)
        }
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.relocateKey = relocateKey
    }

    /// Complete the legacy move, or fail, before the caller opens `record`.
    ///
    /// The capsule moves the key first, WAL/SHM next, and the main database
    /// last. Its ordering makes interrupted runs resumable and preserves the
    /// original estate identity and contents byte-for-byte.
    @discardableResult
    public func run(into record: EstateRecord) throws -> AppContainerLayoutMigration.Outcome {
        let outcome = try AppContainerLayoutMigration.run(
            applicationSupportDirectory: applicationSupportDirectory,
            into: record,
            relocateKey: relocateKey
        )
        if case let .refused(legacy, catalog) = outcome {
            throw Error.conflictingDefaultEstates(legacy: legacy, catalog: catalog)
        }
        return outcome
    }

    /// Prepare the app-private source and only then publish the shared
    /// readiness marker. A conflict, key error, rename error, or marker-write
    /// error propagates; callers must not activate storage creation.
    @discardableResult
    public func runAndMarkReady(
        into record: EstateRecord,
        readiness: LegacyAppEstateReadiness
    ) throws -> AppContainerLayoutMigration.Outcome {
        let outcome = try run(into: record)
        try readiness.markReady()
        return outcome
    }
}

#endif
