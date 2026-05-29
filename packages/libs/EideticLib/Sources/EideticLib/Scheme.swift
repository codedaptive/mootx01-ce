// Scheme.swift
//
// The classification scheme abstraction. EideticLib's default
// scheme is MDCC, the private Moot Decimal Classification Codes
// scheme. The default ships complete with the kit's bundle and
// is resolvable without any network access — its canon comes from
// LatticeKit and its manifest is derived from the bundled canon
// version (see EideticLib.defaultSchemeManifest()).
//
// Foreign schemes — anything under a share-alike or attribution
// licence — are reachable only through the opt-in fetch-and-
// assemble pipeline gated by ActivationConsent. They never ship
// inside the binary. See ConsentGate.swift and
// ForeignSourcePipeline.swift.

import Foundation

/// A classification scheme that EideticLib can ground a term against.
///
/// `mdcc` is the default and always available offline. The foreign
/// schemes (Wikidata, DDC, LCSH, ...) are addressable by name and
/// only become resolvable once the user accepts the activation
/// consent gate and the fetch-and-assemble pipeline has run on
/// their machine.
public enum ClassificationScheme: Sendable, Hashable, Codable {

    /// The private MDCC scheme. Shipped complete, no fetch.
    case mdcc

    /// A foreign-licensed scheme identified by stable name. Only
    /// resolvable post-activation. The associated value is the
    /// stable identifier published in the source registry (e.g.
    /// "wikidata", "ddc", "lcsh").
    case foreign(String)

    /// True if this scheme ships complete with the binary and
    /// requires no consent or network to resolve.
    public var isDefault: Bool {
        switch self {
        case .mdcc: return true
        case .foreign: return false
        }
    }
}

/// The bundled manifest for the MDCC default scheme. Carries the
/// canon version, license note, and offline-resolution flag so
/// callers can confirm the scheme is loaded without consulting
/// any network resource.
public struct LatticeSchemeManifest: Sendable, Hashable, Codable {

    /// The MDCC canon version this manifest pins. Matches the
    /// canonVersion field LatticeKit publishes on its canon bundle.
    public let canonVersion: String

    /// The reference data version. Distinct from canon version
    /// because patch updates may ship without a canon cut.
    public let dataVersion: String

    /// Human-readable license note. MDCC is original work; the
    /// scheme itself is unlicensed. Leaves built from foreign data
    /// carry their own attribution — those leaves are NOT in this
    /// default scheme.
    public let licenseNote: String

    /// True when this manifest can be resolved with no network.
    /// Always true for the bundled MDCC default — kept as an
    /// explicit field to make the invariant testable.
    public let offlineResolvable: Bool

    enum CodingKeys: String, CodingKey {
        case canonVersion = "canon_version"
        case dataVersion = "data_version"
        case licenseNote = "license_note"
        case offlineResolvable = "offline_resolvable"
    }
}
