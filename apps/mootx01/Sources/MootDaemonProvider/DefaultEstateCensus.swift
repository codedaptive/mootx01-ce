import Foundation
import AriaMCP

// MARK: - MACD-2c2 — the default-estate census (KONG-2)
//
// The census is PURE OBSERVATION plus one pure disposition function, the
// exact shape of `ArbiterObservation` + `ProviderArbiter.arbitrate`: the
// caller assembles a snapshot of every legacy default-estate candidate, and
// `DefaultEstateCensus.judge` maps that snapshot deterministically onto one
// of five dispositions. Pure on purpose — a census that reads the world while
// judging it can be raced; this one judges an assembled snapshot, so two
// judges given the same observation MUST agree, which the golden-vector tests
// pin.
//
// Conservatism is the contract (KONG-2): a candidate whose estate identity
// cannot be verified classifies TOWARD the hard stop, never toward "one
// valid". Unverifiable includes a live (non-empty) WAL — an unquiesced source
// has no stable identity to verify. MULTIPLE_ESTATES_HARD_STOP is never
// auto-resolved: no newest-wins, no merge, no overwrite, no delete, no silent
// default. Human authority selects, in a later governed action.
//
// The observation ASSEMBLY has two production tiers:
//   - the file-level tier (presence, bytes, device/inode/link posture, SHA-256
//     digest, encryption posture from the SQLite magic header, key
//     reachability via a read-only probe, receipt lineage) is implementable
//     with this module's own primitives and ships in the shell's census mode;
//   - the identity tier (read-only estate UUID / schema / anchor counts)
//     crosses the injected `SourceEstateAccess` seam, which has no production
//     conformer in this module (frozen package graph — the conformer arrives
//     with MACD-3 estate routing). A production census therefore reports
//     those candidates as identity-unverifiable, and the judge hard-stops
//     conservatively rather than electing anything.

/// The census candidate classes. These are the CLASS LABELS census output and
/// logs carry — never raw foreign paths (Perkins P-c2-8/P-c2-11).
public enum EstateCandidateClass: String, CaseIterable, Sendable, Equatable {
    /// Sandboxed Pro app-local `Application Support/mootx01/mootx01.sqlite`
    /// (inside the Pro app's own container).
    case sandboxedPro = "sandboxed-pro"
    /// Unsandboxed Community `Application Support/mootx01/mootx01.sqlite`.
    case community
    /// Swift CLI legacy `Application Support/com.mootx01.ce/estate.sqlite`.
    case swiftCE = "swift-ce"
    /// Rust CLI legacy `Application Support/ai.mootx01.ce` default.
    case rustCE = "rust-ce"
    /// The canonical App Group default estate.
    case canonical
}

/// Encryption posture of a candidate's main database file, judged from the
/// file's first sixteen bytes: a plaintext SQLite database begins with the
/// documented magic `"SQLite format 3\0"`; a SQLCipher database's first page
/// is ciphertext and carries no magic. No SQL is executed to classify.
public enum EncryptionPosture: String, Sendable, Equatable {
    /// The SQLite plaintext magic is present.
    case plaintext
    /// The magic is absent — ciphertext (or at minimum not plaintext SQLite).
    case encrypted
    /// The file exists but could not be read for classification.
    case unreadable
}

/// Whether the candidate's estate key is reachable WITHOUT minting
/// (Perkins P-c2-8: census mints nothing; the provider's fatal-vs-absence
/// matrix applies — `errSecMissingEntitlement` is fatal, never absence).
public enum KeyReachability: String, Sendable, Equatable {
    /// A read-only probe found the key.
    case reachableWithoutMint = "reachable-without-mint"
    /// Genuine `errSecItemNotFound`.
    case absent
    /// A fatal Keychain classification (missing entitlement, interaction
    /// required, unavailable).
    case fatal
    /// Not applicable (plaintext candidate).
    case notApplicable = "not-applicable"
    /// The census run did not probe key custody (the file-level census mode
    /// runs without the signed Keychain surface and reports so honestly —
    /// never turning an unprobed question into an answer).
    case notProbed = "not-probed"
}

/// Receipt-lineage coverage of a candidate: whether a durable migration
/// receipt names this candidate as an already-migrated source, and whether
/// its recorded digest still matches the candidate's bytes.
public enum ReceiptCoverage: String, Sendable, Equatable {
    /// No receipt names this candidate.
    case none
    /// A committed receipt names it and the digest is unchanged — the
    /// retained source of a completed migration.
    case coveredUnchanged = "covered-unchanged"
    /// A committed receipt names it but the bytes have since changed — the
    /// source DIVERGED after migration.
    case coveredChanged = "covered-changed"
}

/// The read-only identity block of a candidate (estate UUID, schema, anchor
/// counts), produced only through the injected `SourceEstateAccess` seam.
/// Carries identifiers and counts — never a path or key.
public struct CensusIdentity: Sendable, Equatable {
    /// The estate's identity UUID.
    public let estateIdentifier: UUID
    /// The estate's schema version.
    public let schemaVersion: UInt64
    /// Read-only anchor row counts (e.g. drawers, kg_facts) for receipt
    /// binding and post-copy verification.
    public let anchorCounts: [String: UInt64]

    public init(estateIdentifier: UUID, schemaVersion: UInt64, anchorCounts: [String: UInt64]) {
        self.estateIdentifier = estateIdentifier
        self.schemaVersion = schemaVersion
        self.anchorCounts = anchorCounts
    }
}

/// One candidate's census record — pure observation, no judgment.
public struct CensusCandidateRecord: Sendable, Equatable {

    /// The main database file's posture. Presence carries the identity facts
    /// the stale-resolution policy re-verifies against (P-c2-6): size,
    /// device/inode, link count, and content digest.
    public enum Main: Sendable, Equatable {
        /// No main file at the candidate's derived location.
        case absent
        /// The main file with its identity facts.
        case present(bytes: UInt64, device: UInt64, inode: UInt64, linkCount: UInt64, digestSHA256Hex: String)
    }

    /// The candidate's `-wal` sibling posture. A NON-EMPTY WAL means the
    /// source is not quiesced; census never checkpoints (P-c2-8), it reports.
    public enum WAL: Sendable, Equatable {
        /// No `-wal`, or an empty one — checkpointed.
        case absent
        /// A live WAL with content.
        case present(bytes: UInt64)
    }

    /// Which class this record observes.
    public let candidateClass: EstateCandidateClass
    /// Main-file posture.
    public let main: Main
    /// WAL posture.
    public let wal: WAL
    /// Encryption posture.
    public let encryption: EncryptionPosture
    /// Key reachability (without mint).
    public let keyReachability: KeyReachability
    /// The identity block, or `nil` when identity could not be verified —
    /// which classifies conservatively (KONG-2).
    public let identity: CensusIdentity?
    /// Receipt lineage coverage.
    public let receiptCoverage: ReceiptCoverage

    public init(
        candidateClass: EstateCandidateClass,
        main: Main,
        wal: WAL,
        encryption: EncryptionPosture,
        keyReachability: KeyReachability,
        identity: CensusIdentity?,
        receiptCoverage: ReceiptCoverage
    ) {
        self.candidateClass = candidateClass
        self.main = main
        self.wal = wal
        self.encryption = encryption
        self.keyReachability = keyReachability
        self.identity = identity
        self.receiptCoverage = receiptCoverage
    }

    /// Whether the main file exists at all.
    public var isNonEmpty: Bool {
        if case .present = main { return true }
        return false
    }
}

/// A complete census snapshot for judgment.
public struct CensusObservation: Sendable, Equatable {
    /// Every observed NON-canonical candidate record (absent mains included —
    /// the judge filters).
    public let candidates: [CensusCandidateRecord]
    /// The canonical App Group default record, or `nil` when absent.
    public let canonical: CensusCandidateRecord?
    /// Named sibling databases (`databases/<name>`) — REPORTED, never
    /// candidates, never blockers. Names only, no paths.
    public let siblings: [String]

    public init(
        candidates: [CensusCandidateRecord],
        canonical: CensusCandidateRecord?,
        siblings: [String]
    ) {
        self.candidates = candidates
        self.canonical = canonical
        self.siblings = siblings
    }
}

/// Why a census landed in the hard stop.
public enum MultipleEstatesReason: String, Sendable, Equatable {
    /// Two or more nonempty candidates with different identities or content.
    case multipleDistinctCandidates = "multiple-distinct-candidates"
    /// A nonempty candidate whose identity cannot be verified (including an
    /// unquiesced live WAL). Unverifiable never elects (KONG-2).
    case unverifiableCandidate = "unverifiable-candidate"
    /// A receipt-covered source whose bytes changed after migration.
    case divergedFromReceipt = "diverged-from-receipt"
}

/// The five census dispositions (KONG-2). Exhaustive; the judge has no
/// default clause.
public enum CensusDisposition: Sendable, Equatable {
    /// No estate anywhere. Canonical creation is allowed only after provider
    /// lock + credential readiness — a later act, not part of the census.
    case noneFound
    /// Exactly one identity-verified, quiesced candidate.
    case exactlyOneValid(EstateCandidateClass)
    /// Canonical exists and every nonempty legacy candidate is the unchanged
    /// receipt-covered retained source (or there are none).
    case alreadyConverged
    /// Byte-identical, checkpointed, same-UUID duplicates. REPORT — delete
    /// none, elect none automatically.
    case byteIdenticalDuplicates(reported: [EstateCandidateClass])
    /// Human authority required. Never auto-chosen, never silently resolved.
    case multipleEstatesHardStop(MultipleEstatesReason)

    /// The stable wire encoding (self-report surface; the CLI census mode and
    /// the c2 UI key off these spellings).
    public var wireEncoding: String {
        switch self {
        case .noneFound: return "none-found"
        case .exactlyOneValid: return "one-valid"
        case .alreadyConverged: return "already-converged"
        case .byteIdenticalDuplicates: return "byte-identical-duplicates"
        case .multipleEstatesHardStop: return "multiple-estates-hard-stop"
        }
    }

    /// Every wire encoding, in fixed order — part of the canonical
    /// self-report digest.
    public static let allWireEncodings: [String] = [
        "none-found", "one-valid", "already-converged",
        "byte-identical-duplicates", "multiple-estates-hard-stop",
    ]
}

/// The pure census judge.
public enum DefaultEstateCensus {

    /// Judge one census observation.
    ///
    /// Precedence, in order:
    /// 1. Nothing nonempty anywhere → `noneFound`.
    /// 2. Canonical present → every nonempty legacy candidate must be the
    ///    unchanged receipt-covered source (`alreadyConverged`); a changed
    ///    covered source is `divergedFromReceipt`; anything else nonempty
    ///    beside a canonical is the hard stop (a second uncovered estate).
    /// 3. No canonical: any unverifiable nonempty candidate (nil identity or
    ///    live WAL) → hard stop, never an election (KONG-2).
    /// 4. Exactly one verified candidate → `exactlyOneValid`.
    /// 5. Several verified candidates: same UUID AND same digest AND all
    ///    checkpointed → `byteIdenticalDuplicates` (report, delete none);
    ///    anything else → `multipleDistinctCandidates`.
    ///
    /// Siblings never participate (reported upstream, excluded here).
    public static func judge(_ observation: CensusObservation) -> CensusDisposition {
        let nonEmpty = observation.candidates.filter { $0.isNonEmpty }
        let canonicalPresent = observation.canonical?.isNonEmpty == true

        // 1. Nothing anywhere.
        if nonEmpty.isEmpty && !canonicalPresent {
            return .noneFound
        }

        // 2. A canonical estate exists: legacy candidates may only be the
        //    retained, unchanged sources a committed receipt covers.
        if canonicalPresent {
            if nonEmpty.isEmpty { return .alreadyConverged }
            if nonEmpty.contains(where: { $0.receiptCoverage == .coveredChanged }) {
                return .multipleEstatesHardStop(.divergedFromReceipt)
            }
            if nonEmpty.allSatisfy({ $0.receiptCoverage == .coveredUnchanged }) {
                return .alreadyConverged
            }
            // A nonempty legacy estate beside a canonical with NO receipt
            // lineage is a second estate nobody accounted for.
            return .multipleEstatesHardStop(.multipleDistinctCandidates)
        }

        // 3. No canonical. Unverifiable never elects: identity must be
        //    verified AND the source quiesced (empty WAL) to count as valid.
        let unverifiable = nonEmpty.filter { candidate in
            if candidate.identity == nil { return true }
            if case .present = candidate.wal { return true }
            return false
        }
        if !unverifiable.isEmpty {
            return .multipleEstatesHardStop(.unverifiableCandidate)
        }

        // 4. Exactly one verified candidate.
        if nonEmpty.count == 1 {
            return .exactlyOneValid(nonEmpty[0].candidateClass)
        }

        // 5. Several verified candidates: byte-identical same-UUID duplicates
        //    are reported; anything else is the hard stop.
        let identities = Set(nonEmpty.compactMap { $0.identity?.estateIdentifier })
        let digests = Set(nonEmpty.compactMap { candidate -> String? in
            if case .present(_, _, _, _, let digest) = candidate.main { return digest }
            return nil
        })
        if identities.count == 1 && digests.count == 1 {
            return .byteIdenticalDuplicates(reported: nonEmpty.map { $0.candidateClass })
        }
        return .multipleEstatesHardStop(.multipleDistinctCandidates)
    }

    /// The SQLite plaintext magic (`"SQLite format 3\0"`): the first sixteen
    /// bytes of every plaintext database file, per the SQLite file-format
    /// specification. Its ABSENCE classifies a file as not-plaintext
    /// (ciphertext under SQLCipher), with no SQL executed.
    public static let sqliteMagic: [UInt8] = Array("SQLite format 3".utf8) + [0]

    /// Classify a main file's encryption posture from its leading bytes.
    ///
    /// Read-only, bounded (sixteen bytes), through the full hygiene matrix —
    /// census never opens a candidate with SQL and never mints (P-c2-8).
    public static func encryptionPosture(ofMainAt url: URL) -> EncryptionPosture {
        let fd: Int32?
        do {
            fd = try SecureFiles.openValidatedIfExists(url, flags: O_RDONLY)
        } catch {
            return .unreadable
        }
        guard let fd else { return .unreadable }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 16)
        let count = read(fd, &header, 16)
        guard count == 16 else { return .unreadable }
        return header == sqliteMagic ? .plaintext : .encrypted
    }

    /// Observe one candidate location at the FILE level (no identity tier):
    /// presence, size, device/inode/link posture, content digest, WAL
    /// posture, and encryption posture. Strictly read-only.
    ///
    /// - Parameters:
    ///   - candidateClass: The class label for the record.
    ///   - mainURL: The candidate's main database file location, derived by
    ///     the CALLER from its own container/known locations — never from
    ///     any envelope or foreign input (path is never authority).
    ///   - keyReachability: The caller's read-only key probe result.
    ///   - receiptCoverage: The caller's receipt-lineage answer.
    /// - Returns: The observed record, with `identity: nil` (the identity
    ///   tier requires the injected `SourceEstateAccess` seam).
    public static func observeFileLevel(
        candidateClass: EstateCandidateClass,
        mainURL: URL,
        keyReachability: KeyReachability,
        receiptCoverage: ReceiptCoverage
    ) -> CensusCandidateRecord {
        var status = stat()
        guard lstat(mainURL.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return CensusCandidateRecord(
                candidateClass: candidateClass, main: .absent, wal: .absent,
                encryption: .unreadable, keyReachability: keyReachability,
                identity: nil, receiptCoverage: receiptCoverage
            )
        }
        // Digest through a validated descriptor, STREAMED in fixed-size chunks:
        // a real estate is gigabytes, and `mootx01 install` runs this census on
        // real estates, so peak memory must be a constant. An unreadable
        // candidate is reported unreadable, never guessed at.
        let digestHex: String
        do {
            guard let fd = try SecureFiles.openValidatedIfExists(mainURL, flags: O_RDONLY) else {
                return CensusCandidateRecord(
                    candidateClass: candidateClass, main: .absent, wal: .absent,
                    encryption: .unreadable, keyReachability: keyReachability,
                    identity: nil, receiptCoverage: receiptCoverage
                )
            }
            defer { close(fd) }
            digestHex = try SecureFiles.streamingDigestHex(fd: fd)
        } catch {
            return CensusCandidateRecord(
                candidateClass: candidateClass,
                main: .present(
                    bytes: UInt64(status.st_size), device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino), linkCount: UInt64(status.st_nlink),
                    digestSHA256Hex: ""
                ),
                wal: .absent, encryption: .unreadable,
                keyReachability: keyReachability,
                identity: nil, receiptCoverage: receiptCoverage
            )
        }
        // WAL posture: an empty or absent -wal is "absent" (checkpointed);
        // -shm is deliberately ignored — it is never copied and never judged.
        let walURL = URL(fileURLWithPath: mainURL.path + "-wal")
        var walStatus = stat()
        let wal: CensusCandidateRecord.WAL
        if lstat(walURL.path, &walStatus) == 0, walStatus.st_size > 0 {
            wal = .present(bytes: UInt64(walStatus.st_size))
        } else {
            wal = .absent
        }
        return CensusCandidateRecord(
            candidateClass: candidateClass,
            main: .present(
                bytes: UInt64(status.st_size), device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino), linkCount: UInt64(status.st_nlink),
                digestSHA256Hex: digestHex
            ),
            wal: wal,
            encryption: encryptionPosture(ofMainAt: mainURL),
            keyReachability: keyReachability,
            identity: nil,
            receiptCoverage: receiptCoverage
        )
    }
}
