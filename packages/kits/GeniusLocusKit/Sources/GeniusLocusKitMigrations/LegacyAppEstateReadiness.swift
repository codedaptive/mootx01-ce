#if GLK_MIGRATION_APP_CONTAINER_TO_CATALOG

import Foundation

/// Durable app-to-helper handshake for the pre-catalog app-container upgrade.
///
/// A previously enabled login item can launch before the upgraded app. The
/// helper cannot inspect the app's private container, so absence of a legacy
/// estate is not evidence that creating a new canonical estate is safe. The
/// app atomically writes this marker only after `LegacyAppEstatePreparation`
/// has either completed or proved the private legacy database absent.
///
/// Existing canonical databases do not require the marker. This record gates
/// creation only; it never replaces the database as the storage authority.
public struct LegacyAppEstateReadiness: Sendable, Equatable {

    /// Stable file name in the shared catalog configuration directory.
    public static let markerFileName = "legacy-app-estate-ready.v1"

    private static let payload = Data("MOOTX01-LEGACY-APP-ESTATE-READY-v1\n".utf8)

    public enum Error: Swift.Error, Sendable, Equatable {
        /// The canonical database is absent and the app has not published a
        /// complete readiness record. Storage creation must refuse.
        case appPreparationNotConfirmed(marker: URL)
    }

    public let configurationDirectory: URL

    public init(configurationDirectory: URL) {
        self.configurationDirectory = configurationDirectory.standardizedFileURL
    }

    public var markerURL: URL {
        configurationDirectory.appendingPathComponent(Self.markerFileName, isDirectory: false)
    }

    /// Publish readiness with an atomic replace. A crash before the rename
    /// leaves no valid marker; a crash after it leaves the complete payload.
    public func markReady(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: configurationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.payload.write(to: markerURL, options: .atomic)
    }

    /// True only for the complete marker payload. A partial or unfamiliar
    /// record is treated as absent and cannot authorize canonical creation.
    public func isReady(fileManager: FileManager = .default) -> Bool {
        guard let data = try? Data(contentsOf: markerURL) else { return false }
        return data == Self.payload
    }

    /// Permit an existing canonical estate without a marker. When storage is
    /// missing, require the app's complete readiness record before creation.
    public func requireBeforeCreatingCanonical(
        at databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: databaseURL.path) { return }
        guard isReady(fileManager: fileManager) else {
            throw Error.appPreparationNotConfirmed(marker: markerURL)
        }
    }
}

#endif
