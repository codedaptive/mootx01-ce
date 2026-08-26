import Foundation
import CryptoKit

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

/// Which layout produced a lock: the production provider directory, or a
/// proof context nested beneath it. Carried by every lock handle and proof so
/// downstream licenses (the K_install mint above all, Perkins P-c2-1) can be
/// bound to WHERE the serialization actually lives — a proof-directory lock
/// must never license an act against the production credential.
public enum ProviderLayoutContext: String, Sendable, Equatable {
    /// The production provider directory.
    case production
    /// A proof context (or any acquisition that did not positively claim the
    /// production layout — the fail-closed default).
    case proof
}

/// The provider's on-disk layout inside the App Group container. Every state
/// file the substrate owns lives beside the lock, under one directory the
/// hygiene rules validate.
public struct ProviderRootLayout: Sendable, Equatable {

    /// The provider directory: `<container>/Library/Application Support/MOOTx01/provider`
    /// (or a validated proof context beneath it).
    public let providerDirectory: URL

    /// Whether this layout is the production one or a proof context —
    /// stamped by `resolve` and consumed by `ProviderLock.acquire` so the
    /// lock proof carries its provenance (Perkins P-c2-1).
    public let context: ProviderLayoutContext

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

    /// The durable migration-grant consumption journal (MACD-2c2, one-use
    /// enforcement for attended grants — same journal-first shape as leases).
    public var grantJournal: URL { providerDirectory.appendingPathComponent("grant-consumption.journal") }

    /// The durable migration receipt (MACD-2c2, KONG-3 staged→committed
    /// ordering). Lives beside the lock so receipt writes share the hygiene
    /// and serialization guarantees of every other provider state file.
    public var migrationReceiptFile: URL { providerDirectory.appendingPathComponent("migration-receipt.v1.json") }

    /// The migration CHALLENGE file (MACD-2c2): written by the provider when
    /// it enters awaiting-migration-grant, read by the attended app. Beside
    /// the descriptor — not inside the provider directory — because its
    /// reader is a CLIENT process, exactly like the descriptor's readers.
    public var migrationChallengeFile: URL {
        descriptorFile.deletingLastPathComponent()
            .appendingPathComponent("migration-challenge.v1.json")
    }

    /// The migration GRANT envelope file (MACD-2c2, P-c2-5): the ONE place
    /// opaque bookmark bytes may exist. Written by the attended app, consumed
    /// once by the provider, removed after committed success or terminal
    /// abort. Beside the descriptor for the same cross-process reason.
    public var migrationGrantFile: URL {
        descriptorFile.deletingLastPathComponent()
            .appendingPathComponent("migration-grant.v1.json")
    }

    /// Build a layout rooted at an already-resolved provider directory.
    /// Internal: callers go through `resolve`.
    internal init(providerDirectory: URL, descriptorFile: URL, context: ProviderLayoutContext) {
        self.providerDirectory = providerDirectory
        self.descriptorFile = descriptorFile
        self.context = context
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
                descriptorFile: supportDirectory.appendingPathComponent("daemon-descriptor.v2.json"),
                context: .production
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
            descriptorFile: proofDirectory.appendingPathComponent("daemon-descriptor.v2.json"),
            context: .proof
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
        guard let fd = try openValidatedCore(url, flags: flags, create: create, missingIsNil: false) else {
            // Unreachable: missingIsNil=false never returns nil.
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        return fd
    }

    /// `openValidated` for READ paths that must distinguish genuine absence:
    /// returns `nil` on ENOENT and applies the FULL hygiene matrix to
    /// everything that exists. One-use and monotonic records need this shape —
    /// only true absence may answer "no record"; every other fault refuses.
    public static func openValidatedIfExists(
        _ url: URL, flags: Int32
    ) throws -> Int32? {
        try openValidatedCore(url, flags: flags, create: false, missingIsNil: true)
    }

    /// The I/O chunk size for every BOUNDED (streaming) path below: 256 KiB.
    /// Large enough that syscall overhead is irrelevant beside SHA-256 work,
    /// small enough that peak resident memory is a constant regardless of
    /// estate size — a multi-gigabyte estate must never be slurped into RAM
    /// (Perkins/Adams: `mootx01 install` runs the census on real estates).
    public static let streamChunkBytes = 256 * 1024

    /// `read(2)` that retries on `EINTR`. A signal arriving mid-copy is not a
    /// data fault, and turning it into a refusal would make a multi-gigabyte
    /// migration spuriously fail; every OTHER error still throws (fail-closed).
    private static func readRetrying(
        _ fd: Int32, _ buffer: inout [UInt8], _ count: Int
    ) throws -> Int {
        while true {
            let result = read(fd, &buffer, count)
            if result >= 0 { return result }
            if errno == EINTR { continue }
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
    }

    /// `write(2)` of exactly `count` bytes from `buffer`, retrying `EINTR` and
    /// short writes. Returns only when every byte is written.
    private static func writeFully(
        _ fd: Int32, _ buffer: [UInt8], _ count: Int
    ) throws {
        var written = 0
        while written < count {
            let result = buffer.withUnsafeBufferPointer { pointer -> Int in
                write(fd, pointer.baseAddress! + written, count - written)
            }
            if result > 0 {
                written += result
                continue
            }
            if result < 0 && errno == EINTR { continue }
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
    }

    /// `fsync` the directory containing `url` so a newly created or renamed
    /// entry is durable, CHECKED: Perkins P-c2-9 requires the file AND its
    /// parent to be synced, so an unopenable or unsyncable parent is a
    /// durability failure and refuses rather than passing silently.
    internal static func fsyncParentDirectory(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard directoryFD >= 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        defer { close(directoryFD) }
        var result = fsync(directoryFD)
        while result != 0 && errno == EINTR { result = fsync(directoryFD) }
        guard result == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
    }

    /// SHA-256 hex of everything readable from `fd`, computed INCREMENTALLY
    /// over fixed-size chunks. Same algorithm as
    /// `FirstPartyAuthProtocol.sha256` (CryptoKit SHA-256) — the difference is
    /// bounded memory, not a second algebra.
    ///
    /// - Returns: Lowercase hex digest.
    /// - Throws: `DaemonProviderError.hygieneViolation(.unopenable)` on a read
    ///   fault — a partial digest is never returned.
    public static func streamingDigestHex(fd: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: streamChunkBytes)
        while true {
            let count = try readRetrying(fd, &buffer, buffer.count)
            if count == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 hex of the file at `url`, opened through the FULL hygiene
    /// matrix and streamed (bounded memory).
    public static func streamingDigestHex(of url: URL) throws -> String {
        let fd = try openValidated(url, flags: O_RDONLY, create: false)
        defer { close(fd) }
        return try streamingDigestHex(fd: fd)
    }

    /// Copy `source` to `destination` in fixed-size chunks, hashing each chunk
    /// AS IT IS READ and writing that same chunk before the next read, then
    /// `fsync` the file and its parent directory.
    ///
    /// Precisely what the digest covers: the bytes read from `source`, each of
    /// which is then written to completion (a short write is retried until the
    /// chunk is fully written, and any write fault throws). So the digest
    /// describes the source bytes, and the copy is proven complete rather than
    /// the digest being computed from the destination — one pass, no second
    /// read to race, and no window in which a hashed byte went unwritten.
    ///
    /// Streaming and single-pass on purpose: a copy that first slurps and then
    /// re-reads to digest holds the whole estate twice and can be raced
    /// between the two passes.
    ///
    /// The destination is created with `O_EXCL` — a pre-existing file at the
    /// transaction's incoming path is an attack or a bug, and either refuses.
    ///
    /// - Returns: Lowercase hex digest of the copied bytes.
    public static func streamingCopyDigestHex(from source: URL, to destination: URL) throws -> String {
        let sourceFD = try openValidated(source, flags: O_RDONLY, create: false)
        defer { close(sourceFD) }
        let destinationFD = try openValidated(
            destination, flags: O_WRONLY | O_EXCL, create: true
        )
        var closed = false
        defer { if !closed { close(destinationFD) } }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: streamChunkBytes)
        while true {
            let readCount = try readRetrying(sourceFD, &buffer, buffer.count)
            if readCount == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<readCount]))
            }
            try writeFully(destinationFD, buffer, readCount)
        }
        var syncResult = fsync(destinationFD)
        while syncResult != 0 && errno == EINTR { syncResult = fsync(destinationFD) }
        guard syncResult == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        close(destinationFD)
        closed = true
        // The parent fsync is CHECKED (P-c2-9: file AND parent) — a durable
        // file behind a non-durable directory entry is not a durable copy.
        try fsyncParentDirectory(of: destination)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read every byte from a validated descriptor. For SMALL state files
    /// only (descriptor, generations, journal, receipt — all size-bounded by
    /// their own strict decoders). Large-file paths use the streaming
    /// primitives above.
    public static func readAll(fd: Int32) throws -> [UInt8] {
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // EINTR retried here too, so a signal cannot truncate a state
            // record into a "torn" verdict (same posture as the streaming
            // reads; every other error still refuses).
            let count = try readRetrying(fd, &buffer, buffer.count)
            if count == 0 { break }
            bytes.append(contentsOf: buffer[0..<count])
        }
        return bytes
    }

    private static func openValidatedCore(
        _ url: URL, flags: Int32, create: Bool, missingIsNil: Bool
    ) throws -> Int32? {
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
            // Genuine absence is an answer only on read paths that asked for
            // it (one-use and monotonic records); everywhere else it refuses.
            if errno == ENOENT && missingIsNil { return nil }
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
        // Writes and fsync retry EINTR (a signal is not a data fault) and
        // every other error still refuses — aligned with the streaming
        // primitives above so all durable writes share one posture.
        let bytes = [UInt8](data)
        do {
            try writeFully(fd, bytes, bytes.count)
        } catch {
            close(fd)
            throw error
        }
        var syncResult = fsync(fd)
        while syncResult != 0 && errno == EINTR { syncResult = fsync(fd) }
        guard syncResult == 0 else {
            close(fd)
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        close(fd)
        guard rename(temp.path, url.path) == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        cleanupTemp = false
        // fsync the directory so the rename itself is durable — CHECKED, not
        // best-effort: this function's contract is durability, so a parent
        // that cannot be opened or synced is a failure, not a silent pass
        // (Perkins NEW-3; the same rule as the streaming copy above).
        try fsyncParentDirectory(of: url)
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

    /// Which layout produced this lock (Perkins P-c2-1). Immutable after
    /// acquisition; every proof vended from the handle carries it.
    public let layoutContext: ProviderLayoutContext

    internal init(fileDescriptor: Int32, layoutContext: ProviderLayoutContext) {
        self.fileDescriptor = fileDescriptor
        self.layoutContext = layoutContext
    }

    /// The proof token the rest of the pipeline demands. Only a live handle
    /// vends one, and the proof stays valid ONLY while this handle holds the
    /// lock: releasing the handle (or dropping the last reference) invalidates
    /// every outstanding proof, so a stale proof cannot license a mint, a
    /// generation write, or a publication after the lock is gone
    /// (Perkins P4's ordering, enforced at every consumption site through
    /// `ProviderLockProof.validate()`).
    public var proof: ProviderLockProof { ProviderLockProof(owner: self) }

    /// Whether `release()` has run (or the descriptor was closed by deinit).
    public var isReleased: Bool {
        closeOnce.lock()
        defer { closeOnce.unlock() }
        return released
    }

    /// Release the lock by closing the descriptor. Idempotent. Every proof
    /// vended from this handle becomes invalid at this moment.
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
/// live `ProviderLockHandle`, and valid only while that handle still holds
/// the lock — a weak back-reference ties the proof's life to the lock's, so
/// release (or handle deallocation) invalidates it.
public struct ProviderLockProof: Sendable {

    // Weak on purpose: the proof must never keep the lock alive, only
    // observe whether it still is.
    private weak var owner: ProviderLockHandle?

    internal init(owner: ProviderLockHandle) {
        self.owner = owner
    }

    /// Whether the originating handle still holds the lock.
    public var isLive: Bool {
        guard let owner else { return false }
        return !owner.isReleased
    }

    /// The layout context of the originating handle (Perkins P-c2-1). A proof
    /// whose handle is gone answers `.proof` — fail-closed: a dead lock can
    /// never testify to a production layout.
    public var layoutContext: ProviderLayoutContext {
        owner?.layoutContext ?? .proof
    }

    /// Refuse unless the lock is still held.
    ///
    /// - Throws: `DaemonProviderError.lockUnavailable` for a stale proof —
    ///   the caller no longer holds the serialization it is claiming.
    public func validate() throws {
        guard isLive else { throw DaemonProviderError.lockUnavailable }
    }
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
    /// - Parameters:
    ///   - url: The lock file location.
    ///   - context: The layout context that produced `url` (P-c2-1). The
    ///     default is `.proof` — FAIL-CLOSED: an acquisition that does not
    ///     positively claim the production layout can never license a
    ///     production-credential mint. Callers with a resolved
    ///     `ProviderRootLayout` pass `layout.context`.
    /// - Returns: The held lock handle.
    /// - Throws: `DaemonProviderError.lockUnavailable` when another holder
    ///   exists (the caller is the race loser and must perform no further
    ///   side effect); `DaemonProviderError.hygieneViolation` on any P3
    ///   failure.
    public static func acquire(
        at url: URL, context: ProviderLayoutContext = .proof
    ) throws -> ProviderLockHandle {
        let fd = try SecureFiles.openValidated(url, flags: O_RDWR, create: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK { throw DaemonProviderError.lockUnavailable }
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        return ProviderLockHandle(fileDescriptor: fd, layoutContext: context)
    }
}
