import AriaMCPWire
import Foundation
#if os(macOS)
import Security
#endif

/// The daemon states the Community application is allowed to present.
///
/// This is deliberately narrower than process or storage state. The app learns
/// whether it may call the resident daemon and which estate that daemon proved
/// it owns; it never learns an estate path, database handle, or key.
public enum CommunityDaemonConnectionState: Sendable, Equatable {
    case unavailable
    case starting
    case shuttingDown
    case migrating
    case recovering
    case blocked(reason: String)
    case ready(EstateIdentity)
    case incompatible
    case authenticationFailed
    case handshakeFailed
    case updateDaemonRequired(found: SemanticVersion, minimum: SemanticVersion)
    case updateAppRequired(found: SemanticVersion, maximumExclusive: SemanticVersion)
}

/// One atomic observation of the resident daemon.
public struct CommunityDaemonConnection: Sendable {
    public let state: CommunityDaemonConnectionState
    public let caller: (any MootEstateCalling)?

    public init(
        state: CommunityDaemonConnectionState,
        caller: (any MootEstateCalling)? = nil
    ) {
        self.state = state
        self.caller = caller
    }
}

/// The only estate-attachment seam available to the Community UI.
///
/// Conforming values are actors so a reconnect cannot race another reconnect
/// and publish a caller for a superseded daemon instance.
public protocol CommunityDaemonConnecting: Actor, Sendable {
    func connect() async -> CommunityDaemonConnection
}

/// Drives the authenticated readiness ceremony and releases a caller only
/// after every daemon gate succeeds.
public actor CommunityDaemonConnector: CommunityDaemonConnecting {
    private let readiness: DaemonReadiness

    public init(readiness: DaemonReadiness) {
        self.readiness = readiness
    }

    public func connect() async -> CommunityDaemonConnection {
        switch await readiness.connect() {
        case .unavailable:
            return CommunityDaemonConnection(state: .unavailable)
        case .superseded:
            return CommunityDaemonConnection(state: .starting)
        case .incompatible:
            return CommunityDaemonConnection(state: .incompatible)
        case .authenticationFailed:
            return CommunityDaemonConnection(state: .authenticationFailed)
        case .handshakeFailed:
            return CommunityDaemonConnection(state: .handshakeFailed)
        case .updateDaemonRequired(let found, let minimum):
            return CommunityDaemonConnection(
                state: .updateDaemonRequired(found: found, minimum: minimum)
            )
        case .updateAppRequired(let found, let maximumExclusive):
            return CommunityDaemonConnection(
                state: .updateAppRequired(found: found, maximumExclusive: maximumExclusive)
            )
        case .ready(let descriptor):
            guard let caller = await readiness.callerIfReady() else {
                return CommunityDaemonConnection(state: .handshakeFailed)
            }
            switch await CommunityContractIdentity.verify(caller: caller, descriptor: descriptor) {
            case .accepted:
                break
            case .incompatible:
                return CommunityDaemonConnection(state: .incompatible)
            case .failed:
                return CommunityDaemonConnection(state: .handshakeFailed)
            }
            let identity = EstateIdentity.daemon(
                estate: descriptor.estateIdentifier,
                service: descriptor.serviceIdentifier
            )
            return CommunityDaemonConnection(state: .ready(identity), caller: caller)
        }
    }
}

/// Production composition for the Community application's daemon-only route.
public enum CommunityDaemonConnections {
    /// Build the live connector from this process's signed entitlements.
    ///
    /// If the product is missing either entitlement, the returned connector is
    /// permanently unavailable. It never substitutes an embedded estate.
    public static func live() -> any CommunityDaemonConnecting {
        #if os(macOS)
        guard let environment = CommunityDaemonEnvironment.resolve() else {
            return UnavailableCommunityDaemonConnector()
        }

        let rootProvider = CommunityInstallationRootProvider(
            accessGroup: environment.keychainAccessGroup
        )
        let authenticator = FirstPartyDaemonAuthenticator(rootProvider: rootProvider)
        let descriptorURL = environment.descriptorURL
        let readiness = DaemonReadiness(
            loadDescriptor: {
                try CommunityDaemonDescriptorFile.load(from: descriptorURL)
            },
            authenticate: { descriptor in
                try await authenticator.authenticate(descriptor)
            }
        )
        return CommunityDaemonConnector(readiness: readiness)
        #else
        return UnavailableCommunityDaemonConnector()
        #endif
    }
}

private actor UnavailableCommunityDaemonConnector: CommunityDaemonConnecting {
    func connect() async -> CommunityDaemonConnection {
        CommunityDaemonConnection(state: .unavailable)
    }
}

#if os(macOS)
private struct CommunityDaemonEnvironment: Sendable {
    let descriptorURL: URL
    let keychainAccessGroup: String

    static func resolve() -> Self? {
        guard let appGroup = signedEntitlementValues(
            key: "com.apple.security.application-groups"
        ).first(where: { $0.hasSuffix("group.com.codedaptive.mootx01") }),
        let keychainGroup = signedEntitlementValues(
            key: "keychain-access-groups"
        ).first(where: { $0.hasSuffix("com.codedaptive.mootx01.shared") }),
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            return nil
        }

        let descriptorURL = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MOOTx01", isDirectory: true)
            .appendingPathComponent("daemon-descriptor.v2.json", isDirectory: false)
        return Self(descriptorURL: descriptorURL, keychainAccessGroup: keychainGroup)
    }

    private static func signedEntitlementValues(key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(task, key as CFString, nil),
              let values = raw as? [String] else {
            return []
        }
        return values
    }
}

private struct CommunityInstallationRootProvider: FirstPartyInstallationRootProviding {
    private let accessGroup: String

    init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    func installationRoot() async throws -> [UInt8] {
        guard !accessGroup.isEmpty, accessGroup.contains(".") else {
            throw CommunityInstallationRootError.missingEntitlement
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: FirstPartyAuthProtocol.keychainService,
            kSecAttrAccount as String: FirstPartyAuthProtocol.keychainAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecMissingEntitlement:
            throw CommunityInstallationRootError.missingEntitlement
        case errSecItemNotFound:
            throw CommunityInstallationRootError.unavailable
        default:
            throw CommunityInstallationRootError.keychainFailure
        }
        guard let data = item as? Data,
              data.count == FirstPartyAuthProtocol.rootKeyByteCount else {
            throw CommunityInstallationRootError.malformed
        }
        return Array(data)
    }
}

private enum CommunityInstallationRootError: Error {
    case missingEntitlement
    case unavailable
    case keychainFailure
    case malformed
}
#endif

/// Strict reader for the daemon's schema-2 descriptor.
///
/// The daemon encodes generations as decimal strings and its MAC as base64url,
/// so synthesized `Codable` is intentionally not used here. A malformed or
/// widened record is rejected before authentication or network traffic.
public enum CommunityDaemonDescriptorFile {
    private static let maximumBytes = 64 * 1024
    private static let fieldNames: Set<String> = [
        "schemaVersion", "providerIdentifier", "serviceIdentifier", "endpoint",
        "authProtocol", "authKeyIdentifier", "publishedAt", "instanceIdentifier",
        "estateIdentifier", "binaryVersion", "contractRevision", "mcpProtocolVersion",
        "capabilities", "credentialGeneration", "descriptorGeneration", "descriptorMAC",
    ]

    public enum ReadError: Error, Sendable, Equatable {
        case oversized
        case malformed
    }

    public static func load(from url: URL) throws -> DaemonDescriptor? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > maximumBytes {
            throw ReadError.oversized
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else { throw ReadError.oversized }
        guard let descriptor = decode(data) else { throw ReadError.malformed }
        return descriptor
    }

    public static func decode(_ data: Data) -> DaemonDescriptor? {
        guard data.count <= maximumBytes,
              let object = FirstPartyAuthProtocol.strictJSONObject(
                data, expected: fieldNames, maxBytes: maximumBytes
              ),
              let schemaVersion = object["schemaVersion"] as? Int,
              let providerIdentifier = object["providerIdentifier"] as? String,
              let serviceIdentifier = object["serviceIdentifier"] as? String,
              let endpointRaw = object["endpoint"] as? String,
              let endpoint = URL(string: endpointRaw),
              let authProtocol = object["authProtocol"] as? String,
              let authKeyIdentifier = object["authKeyIdentifier"] as? String,
              let publishedAt = FirstPartyAuthProtocol.exactUInt64(object["publishedAt"]),
              let instanceRaw = object["instanceIdentifier"] as? String,
              let instanceIdentifier = UUID(uuidString: instanceRaw),
              let estateRaw = object["estateIdentifier"] as? String,
              let estateIdentifier = UUID(uuidString: estateRaw),
              let binaryVersion = object["binaryVersion"] as? String,
              let contractRevision = object["contractRevision"] as? Int,
              let mcpProtocolVersion = object["mcpProtocolVersion"] as? String,
              let capabilityRaw = object["capabilities"] as? [String],
              let credentialRaw = object["credentialGeneration"] as? String,
              let credentialGeneration = exactGeneration(credentialRaw),
              let descriptorRaw = object["descriptorGeneration"] as? String,
              let descriptorGeneration = exactGeneration(descriptorRaw),
              let macRaw = object["descriptorMAC"] as? String,
              let descriptorMAC = FirstPartyAuthProtocol.base64URLDecode(macRaw),
              descriptorMAC.count == FirstPartyAuthProtocol.macByteCount else {
            return nil
        }

        let capabilities = capabilityRaw.compactMap(DaemonCapability.init(rawValue:))
        guard capabilities.count == capabilityRaw.count,
              Set(capabilityRaw).count == capabilityRaw.count else {
            return nil
        }

        return DaemonDescriptor(
            schemaVersion: schemaVersion,
            providerIdentifier: providerIdentifier,
            serviceIdentifier: serviceIdentifier,
            instanceIdentifier: instanceIdentifier,
            estateIdentifier: estateIdentifier,
            binaryVersion: binaryVersion,
            contractRevision: contractRevision,
            mcpProtocolVersion: mcpProtocolVersion,
            endpoint: endpoint,
            capabilities: Set(capabilities),
            authProtocol: authProtocol,
            authKeyIdentifier: authKeyIdentifier,
            publishedAt: publishedAt,
            credentialGeneration: credentialGeneration,
            descriptorGeneration: descriptorGeneration,
            descriptorMAC: descriptorMAC
        )
    }

    private static func exactGeneration(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value == "0" || !value.hasPrefix("0"),
              value.allSatisfy(\.isNumber) else {
            return nil
        }
        return UInt64(value)
    }
}
