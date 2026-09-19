import AriaMCPWire
import AriaMCP
import Foundation

/// The native client's fixed expectation for the daemon-owned provider.
///
/// The server advertises five discovery fields during the authenticated MCP
/// initialization handshake. The client validates every field before a caller
/// can escape readiness, then carries only the three compatibility fields the
/// stable `tools/call` grammar requires.
public struct FirstPartyProviderClientContract: Sendable, Equatable {
    public let providerName: String
    public let contractVersion: String
    public let ariaSupportedVersion: String
    public let capabilities: [String]
    public let capabilityDigest: String

    public init(
        providerName: String,
        contractVersion: String,
        ariaSupportedVersion: String,
        capabilities: [String],
        capabilityDigest: String
    ) {
        self.providerName = providerName
        self.contractVersion = contractVersion
        self.ariaSupportedVersion = ariaSupportedVersion
        self.capabilities = capabilities
        self.capabilityDigest = capabilityDigest
    }

    /// Validate the exact discovery object and derive the call metadata from it.
    /// Unknown, missing, reordered, or duplicate capability entries fail closed.
    public func validate(discovery value: JSONValue?) -> FirstPartyProviderCompatibility? {
        guard let object = value?.objectValue,
              Set(object.keys) == [
                "provider", "contract_version", "aria_supported_version",
                "capabilities", "capability_digest",
              ],
              object["provider"]?.stringValue == providerName,
              object["contract_version"]?.stringValue == contractVersion,
              object["aria_supported_version"]?.stringValue == ariaSupportedVersion,
              object["capabilities"]?.arrayValue?.compactMap(\.stringValue) == capabilities,
              object["capability_digest"]?.stringValue == capabilityDigest else {
            return nil
        }
        return FirstPartyProviderCompatibility(
            contractVersion: contractVersion,
            ariaSupportedVersion: ariaSupportedVersion,
            capabilityDigest: capabilityDigest
        )
    }
}

public extension FirstPartyProviderClientContract {
    /// The provider tuple this native client was built to call. Keeping the
    /// construction here makes Community and Pro perform the same exact
    /// discovery negotiation before either caller escapes readiness.
    static let current = FirstPartyProviderClientContract(
        providerName: FirstPartyProviderCatalog.providerName,
        contractVersion: FirstPartyProviderCatalog.contractVersion,
        ariaSupportedVersion: FirstPartyProviderCatalog.supportedARIAVersion,
        capabilities: FirstPartyProviderCatalog.capabilities,
        capabilityDigest: FirstPartyProviderCatalog.capabilityDigest
    )
}

/// The exact three-field record attached to every stable provider call.
public struct FirstPartyProviderCompatibility: Sendable, Equatable {
    public let contractVersion: String
    public let ariaSupportedVersion: String
    public let capabilityDigest: String

    public init(
        contractVersion: String,
        ariaSupportedVersion: String,
        capabilityDigest: String
    ) {
        self.contractVersion = contractVersion
        self.ariaSupportedVersion = ariaSupportedVersion
        self.capabilityDigest = capabilityDigest
    }

    public var jsonValue: JSONValue {
        .object([
            "contract_version": .string(contractVersion),
            "aria_supported_version": .string(ariaSupportedVersion),
            "capability_digest": .string(capabilityDigest),
        ])
    }
}
