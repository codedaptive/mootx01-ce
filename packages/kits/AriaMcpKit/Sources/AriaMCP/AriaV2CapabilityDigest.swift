import CryptoKit
import Foundation
import AriaMCPWire

/// Canonical, build-independent identity of an effective ARIA v2 capability
/// catalog.  This core is intentionally independent of selected-surface
/// wiring: callers supply the effective descriptors already chosen for their
/// lane and capability inputs.
public enum AriaV2CapabilityDigest {
    /// SHA-256 of canonical UTF-8 JSON for the supplied effective operations.
    ///
    /// `buildID` is intentionally absent from the material.  A build may
    /// report its own identity beside this digest, but a volatile build value
    /// must not change the capability identity when the effective definitions
    /// are unchanged.
    public static func digest(
        descriptors: [AriaV2OperationDescriptor],
        recipeBindings: [AriaV2OperationIdentity: [String]] = [:]
    ) throws -> String {
        let canonical = try canonicalJSON(
            descriptors: descriptors,
            recipeBindings: recipeBindings
        )
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Convenience overload for a registry after it has applied its explicit
    /// build/lane/capability availability selection.  Registry inputs are not
    /// serialized; selected operation definitions are the digest authority.
    public static func digest(
        registry: AriaV2EffectiveRegistry,
        recipeBindings: [AriaV2OperationIdentity: [String]] = [:]
    ) throws -> String {
        try digest(descriptors: registry.operations, recipeBindings: recipeBindings)
    }

    /// Exposed for cross-port vectors and source-faithful digest diagnostics.
    /// Object keys are UTF-8-byte sorted, operation definitions are sorted by
    /// public name then stable identity, and arrays retain their supplied
    /// order.  `JSONValue.double` rejects non-finite values because they are
    /// not JSON scalars.
    public static func canonicalJSON(
        descriptors: [AriaV2OperationDescriptor],
        recipeBindings: [AriaV2OperationIdentity: [String]] = [:]
    ) throws -> String {
        let definitions = try descriptors
            .sorted(by: descriptorPrecedes)
            .map { descriptor in
                try canonicalDefinition(
                    descriptor,
                    recipeBindings: recipeBindings[descriptor.identity] ?? []
                )
            }
        return "{\"operations\":[\(definitions.joined(separator: ","))]}"
    }

    private static func canonicalDefinition(
        _ descriptor: AriaV2OperationDescriptor,
        recipeBindings: [String]
    ) throws -> String {
        let help = try canonicalObject([
            "description": try canonicalString(descriptor.help.description),
            "example": try descriptor.help.example.map(canonicalValue) ?? "null",
            "intents": try canonicalStringArray(descriptor.help.intents),
        ])
        return try canonicalObject([
            "availability": "true",
            "effect": try canonicalString(descriptor.effect.rawValue),
            "help": help,
            "identity": try canonicalString(descriptor.identity.rawValue),
            "input_schema": try canonicalValue(descriptor.inputSchema),
            "name": try canonicalString(descriptor.publicName),
            "output_schema": try canonicalValue(descriptor.projection.outputSchema),
            "recipe_bindings": try canonicalStringArray(recipeBindings.sorted(by: utf8Precedes)),
        ])
    }

    private static func canonicalValue(_ value: JSONValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return String(value)
        case .double(let value):
            guard value.isFinite else {
                throw AriaV2CapabilityDigestError.nonFiniteDouble(value)
            }
            return String(value)
        case .string(let value):
            return try canonicalString(value)
        case .array(let values):
            return "[\(try values.map(canonicalValue).joined(separator: ","))]"
        case .object(let values):
            var members: [String: String] = [:]
            members.reserveCapacity(values.count)
            for (key, nested) in values {
                members[key] = try canonicalValue(nested)
            }
            return try canonicalObject(members)
        }
    }

    private static func canonicalObject(_ members: [String: String]) throws -> String {
        let fields = try members.keys.sorted(by: utf8Precedes).map { key in
            "\(try canonicalString(key)):\(members[key]!)"
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private static func canonicalStringArray(_ values: [String]) throws -> String {
        "[\(try values.map(canonicalString).joined(separator: ","))]"
    }

    private static func canonicalString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func descriptorPrecedes(
        _ lhs: AriaV2OperationDescriptor,
        _ rhs: AriaV2OperationDescriptor
    ) -> Bool {
        if lhs.publicName == rhs.publicName {
            return utf8Precedes(lhs.identity.rawValue, rhs.identity.rawValue)
        }
        return utf8Precedes(lhs.publicName, rhs.publicName)
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

public enum AriaV2CapabilityDigestError: Error, Equatable {
    case nonFiniteDouble(Double)
}
