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

    /// The published descriptor. In the production layout it sits beside —
    /// not inside — the provider directory (readers are clients, and the
    /// provider directory itself never needs to be readable by them); in a
    /// proof context it nests INSIDE the context so a proof run can never
    /// write at the production descriptor location.
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
        guard let container = resolver.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            throw DaemonProviderError.rootUnresolvable
        }
        let supportDirectory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MOOTx01", isDirectory: true)
        let productionProvider = supportDirectory.appendingPathComponent("provider", isDirectory: true)

        guard let context = proofContext else {
            return ProviderRootLayout(
                providerDirectory: productionProvider,
                descriptorFile: supportDirectory.appendingPathComponent("daemon-descriptor.v2.json")
            )
        }
        // The context is a NAME: it must round-trip through UUID parsing, so
        // no separator, dot-dot, or path fragment can survive into the tree.
        guard let contextUUID = UUID(uuidString: context) else {
            throw DaemonProviderError.rootUnresolvable
        }
        let proofDirectory = productionProvider
            .appendingPathComponent("proof", isDirectory: true)
            .appendingPathComponent(contextUUID.uuidString, isDirectory: true)
        return ProviderRootLayout(
            providerDirectory: proofDirectory,
            descriptorFile: proofDirectory.appendingPathComponent("daemon-descriptor.v2.json")
        )
    }
}

/// Hygiene-validated filesystem primitives (Perkins P3). Public so the tests
/// can drive each refusal directly rather than trusting a comment.
public enum SecureFiles {

    /// Create (0o700) and validate the directory chain down to `directory`.
    ///
    /// Pre-existing intermediate directories (the system-owned container
    /// spine) are left as they are; the FINAL directory — the one that will
    /// hold the lock and state files — is validated: owned by the effective
    /// uid, no group/other write.
    ///
    /// - Throws: `DaemonProviderError.hygieneViolation`.
    public static func ensureProviderDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        var status = stat()
        guard lstat(directory.path, &status) == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            // A symlink or file where the provider directory should be.
            throw DaemonProviderError.hygieneViolation(.symlink)
        }
        guard status.st_uid == geteuid() else {
            throw DaemonProviderError.hygieneViolation(.foreignOwner)
        }
        guard status.st_mode & 0o022 == 0 else {
            throw DaemonProviderError.hygieneViolation(.permissiveMode)
        }
    }

    /// Open `url` with `O_NOFOLLOW|O_CLOEXEC` (plus `flags`), optionally
    /// creating it 0o600, then validate: parent owned by the effective uid
    /// with no group/other write; `fstat` reports a regular file with
    /// `st_nlink == 1`.
    ///
    /// The parent checks run BEFORE the open so a create never lands a file
    /// in a directory another principal could rewrite; the fstat checks run
    /// on the DESCRIPTOR so nothing can be swapped between check and use
    /// (the c0 `journalContains` fd pattern).
    ///
    /// - Returns: The validated file descriptor. The caller owns and closes it.
    /// - Throws: `DaemonProviderError.hygieneViolation` naming the violated
    ///   invariant.
    public static func openValidated(
        _ url: URL, flags: Int32, create: Bool
    ) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        guard parentStatus.st_uid == geteuid() else {
            throw DaemonProviderError.hygieneViolation(.foreignOwner)
        }
        guard parentStatus.st_mode & 0o022 == 0 else {
            throw DaemonProviderError.hygieneViolation(.permissiveMode)
        }

        var openFlags = flags | O_NOFOLLOW | O_CLOEXEC
        if create { openFlags |= O_CREAT }
        let fd = open(url.path, openFlags, 0o600)
        guard fd >= 0 else {
            // O_NOFOLLOW refuses a symlink terminal component with ELOOP.
            if errno == ELOOP { throw DaemonProviderError.hygieneViolation(.symlink) }
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            close(fd)
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw DaemonProviderError.hygieneViolation(.notRegularFile)
        }
        guard status.st_nlink == 1 else {
            close(fd)
            throw DaemonProviderError.hygieneViolation(.hardLink)
        }
        return fd
    }

    /// Durable atomic replace: write to a temp sibling, `fsync` the file,
    /// `rename(2)` over the destination, then `fsync` the directory. The
    /// destination is either the old bytes or the new bytes — never a torn
    /// intermediate (Perkins P6/P8).
    public static func atomicReplace(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        // O_EXCL: the temp name is fresh; anything already there is an attack
        // or a bug, and either refuses.
        let fd = try openValidated(temp, flags: O_WRONLY | O_EXCL, create: true)
        var cleanupTemp = true
        defer {
            if cleanupTemp { unlink(temp.path) }
        }
        var written = 0
        let bytes = [UInt8](data)
        while written < bytes.count {
            let result = bytes.withUnsafeBufferPointer { buffer -> Int in
                write(fd, buffer.baseAddress! + written, bytes.count - written)
            }
            guard result > 0 else {
                close(fd)
                throw DaemonProviderError.hygieneViolation(.unopenable)
            }
            written += result
        }
        guard fsync(fd) == 0 else {
            close(fd)
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        close(fd)
        guard rename(temp.path, url.path) == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        cleanupTemp = false
        // fsync the directory so the rename itself is durable.
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        if directoryFD >= 0 {
            fsync(directoryFD)
            close(directoryFD)
        }
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
    /// `flock` contention is judged per open file description, so two
    /// processes AND two independent opens in one process both contend —
    /// which is what lets the in-process race tests prove the same property
    /// the two-shell live proof re-proves across processes.
    ///
    /// - Returns: The held lock handle.
    /// - Throws: `DaemonProviderError.lockUnavailable` when another holder
    ///   exists (the caller is the race loser and must perform no further
    ///   side effect); `DaemonProviderError.hygieneViolation` on any P3
    ///   failure.
    public static func acquire(at url: URL) throws -> ProviderLockHandle {
        let fd = try SecureFiles.openValidated(url, flags: O_RDWR, create: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK { throw DaemonProviderError.lockUnavailable }
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        return ProviderLockHandle(fileDescriptor: fd)
    }
}
