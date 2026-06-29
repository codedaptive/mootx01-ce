// PlatformCryptoCandidate.swift
//
// Apple-system SHA-256/HMAC candidate for NT-P0 bakeoffs. Kept in a
// separate target so the benchmark runner can compare it against the
// in-repo SubstrateKernel scalar reference without a SHA256 type-name
// collision.

#if canImport(CryptoKit)
import CryptoKit
import Foundation

public enum PlatformCryptoCandidate {
    public static let isAvailable = true
    public static let implementationName = "cryptokit"

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: Data(bytes)))
    }

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: Data(key))
        return hmacSHA256(using: symmetricKey, data: data)
    }

    /// Pre-keyed HMAC for measurement loops. The SymmetricKey is created
    /// once by the caller and reused — matching production usage where the
    /// estate key is long-lived. The previous single-method API created
    /// the key on every call, which inflated 256B HMAC timings by ~2.4x
    /// due to allocation overhead.
    public static func makeSymmetricKey(_ key: [UInt8]) -> SymmetricKey {
        SymmetricKey(data: Data(key))
    }

    public static func hmacSHA256(using symmetricKey: SymmetricKey, data: [UInt8]) -> [UInt8] {
        Array(HMAC<CryptoKit.SHA256>.authenticationCode(for: Data(data), using: symmetricKey))
    }
}
#else
public enum PlatformCryptoCandidate {
    public static let isAvailable = false
    public static let implementationName = "unavailable"

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        preconditionFailure("Platform crypto is unavailable on this platform")
    }

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        preconditionFailure("Platform crypto is unavailable on this platform")
    }

    public static func makeSymmetricKey(_ key: [UInt8]) -> Any {
        preconditionFailure("Platform crypto is unavailable on this platform")
    }

    public static func hmacSHA256(using symmetricKey: Any, data: [UInt8]) -> [UInt8] {
        preconditionFailure("Platform crypto is unavailable on this platform")
    }
}
#endif
