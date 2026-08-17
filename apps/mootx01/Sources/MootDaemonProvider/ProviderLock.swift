import Foundation

// MARK: - MACD-2c1 — provider root, filesystem hygiene, and the exclusive lock
//
// Perkins P2: the provider root comes EXCLUSIVELY from the injected App Group
// resolver. There is no argv, environment, cwd, or descriptor-derived root.
//
// Perkins P3: every open of the root, lock, or a state file uses
// O_NOFOLLOW|O_CLOEXEC; parents must be owned by the effective uid with no
// group/other write; every opened descriptor must be a regular file with link
// count 1 (the c0 DaemonHelper journal pattern, generalized).
//
// Perkins P4: the exclusive flock is held BEFORE any Keychain mint, estate
// lifecycle request, bind, or descriptor publication. The race loser exits
// with zero side-effect callbacks.

/// Resolves the App Group container. Production: `FileManager`'s
/// `containerURL(forSecurityApplicationGroupIdentifier:)` — the ONLY
/// authorized source of the provider root (Kong decision 4). Injected so
/// tests can point the substrate at scratch roots without weakening P2.
public protocol ProviderRootResolving: Sendable {
    /// The container URL for `groupIdentifier`, or `nil` when unresolvable.
    func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL?
}

/// The production resolver: asks the OS for the App Group container.
public struct AppGroupRootResolver: ProviderRootResolving {
    public init() {}

    /// Resolve via `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
    public func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }
}

/// The provider's on-disk layout inside the App Group container. Every state
/// file the substrate owns lives beside the lock, under one directory the
/// hygiene rules validate.
public struct ProviderRootLayout: Sendable, Equatable {

    /// The provider directory: `<container>/Library/Application Support/MOOTx01/provider`
    /// (or a validated proof context beneath it).
    public let providerDirectory: URL

    /// The exclusive provider lock file.
    public var lockFile: URL { providerDirectory.appendingPathComponent("provider.lock") }

    /// The durable generation record (Perkins P6; the durable watermark
    /// MACD-2b §Deviations deferred to this mission).
    public var generationsFile: URL { providerDirectory.appendingPathComponent("generations.v1") }

    /// The lease consumption journal (single-use enforcement, c0 journal-first
    /// pattern).
    public var leaseJournal: URL { providerDirectory.appendingPathComponent("lease-consumption.journal") }

    /// The published descriptor: `<container>/Library/Application Support/MOOTx01/daemon-descriptor.v2.json`.
    /// Beside — not inside — the provider directory: readers are clients, and
    /// the provider directory itself never needs to be readable by them.
    public let descriptorFile: URL

    /// Build a layout rooted at an already-resolved provider directory.
    /// Internal: callers go through `resolve`.
    internal init(providerDirectory: URL, descriptorFile: URL) {
        self.providerDirectory = providerDirectory
        self.descriptorFile = descriptorFile
    }

    /// Resolve the layout through the injected resolver (Perkins P2).
    ///
    /// - Parameters:
    ///   - resolver: The injected App Group resolver.
    ///   - groupIdentifier: The App Group to resolve.
    ///   - proofContext: When non-nil, a UUID STRING naming a proof namespace
    ///     nested beneath the provider directory. The value must parse as a
    ///     UUID — it is a leaf name, never a path, so a proof driver can name
    ///     a scratch context without ever supplying a root (P2 preserved; the
    ///     shell's argv carries a context NAME, not a location).
    /// - Throws: `DaemonProviderError.rootUnresolvable` when the resolver
    ///   returns nil or the proof context is not a UUID.
    public static func resolve(
        resolver: any ProviderRootResolving,
        groupIdentifier: String,
        proofContext: String? = nil
    ) throws -> ProviderRootLayout {
        throw DaemonProviderError.unimplemented("ProviderRootLayout.resolve")
    }
}

/// Hygiene-validated filesystem primitives (Perkins P3). Public so the tests
/// can drive each refusal directly rather than trusting a comment.
public enum SecureFiles {

    /// Create (0o700) and validate the directory chain from `base` down to
    /// `directory`. Validation on each created/validated component: owner is
    /// the effective uid; mode carries no group/other write.
    ///
    /// - Throws: `DaemonProviderError.hygieneViolation`.
    public static func ensureProviderDirectory(_ directory: URL) throws {
        throw DaemonProviderError.unimplemented("SecureFiles.ensureProviderDirectory")
    }

    /// Open `url` with `O_NOFOLLOW|O_CLOEXEC` (plus `flags`), optionally
    /// creating it 0o600, then validate: parent owned by the effective uid
    /// with no group/other write; `fstat` reports a regular file with
    /// `st_nlink == 1`.
    ///
    /// - Returns: The validated file descriptor. The caller owns and closes it.
    /// - Throws: `DaemonProviderError.hygieneViolation` naming the violated
    ///   invariant.
    public static func openValidated(
        _ url: URL, flags: Int32, create: Bool
    ) throws -> Int32 {
        throw DaemonProviderError.unimplemented("SecureFiles.openValidated")
    }

    /// Durable atomic replace: write to a temp sibling, `fsync` the file,
    /// `rename(2)` over the destination, then `fsync` the directory. The
    /// destination is either the old bytes or the new bytes — never a torn
    /// intermediate (Perkins P6/P8).
    public static func atomicReplace(_ data: Data, at url: URL) throws {
        throw DaemonProviderError.unimplemented("SecureFiles.atomicReplace")
    }
}

/// The held exclusive provider lock. A class so release is tied to object
/// lifetime: dropping the last reference closes the descriptor, which
/// releases the `flock`. `@unchecked Sendable` because the only mutable state
/// is the close-once flag, guarded by `NSLock`.
public final class ProviderLockHandle: @unchecked Sendable {

    private let fileDescriptor: Int32
    private let closeOnce = NSLock()
    private var released = false

    internal init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// The proof token the rest of the pipeline demands. Only a live handle
    /// vends one, so a `ProviderLockProof` in hand IS evidence the lock is
    /// held (Perkins P4's ordering, enforced by the type system).
    public var proof: ProviderLockProof { ProviderLockProof() }

    /// Release the lock by closing the descriptor. Idempotent.
    public func release() {
        closeOnce.lock()
        defer { closeOnce.unlock() }
        guard !released else { return }
        released = true
        close(fileDescriptor)
    }

    deinit { release() }
}

/// Proof that the exclusive provider lock is held. Constructible only from a
/// live `ProviderLockHandle`.
public struct ProviderLockProof: Sendable {
    internal init() {}
}

/// Acquires the exclusive provider lock.
public enum ProviderLock {

    /// Open the lock file with full hygiene validation and take
    /// `flock(LOCK_EX | LOCK_NB)`.
    ///
    /// - Returns: The held lock handle.
    /// - Throws: `DaemonProviderError.lockUnavailable` when another holder
    ///   exists (the caller is the race loser and must perform no further
    ///   side effect); `DaemonProviderError.hygieneViolation` on any P3
    ///   failure.
    public static func acquire(at url: URL) throws -> ProviderLockHandle {
        throw DaemonProviderError.unimplemented("ProviderLock.acquire")
    }
}
