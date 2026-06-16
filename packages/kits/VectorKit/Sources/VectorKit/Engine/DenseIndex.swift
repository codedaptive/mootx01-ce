// DenseIndex.swift
//
// The engine seam: one protocol, two implementations (Lane A
// BruteForceIndex, Lane B MIHIndex).
//
// Lane F foundation type. Defining the protocol here before any
// implementation means all lanes depend on the seam interface — not
// on each other's implementation. A consumer that holds a `DenseIndex`
// does not need to know which lane is behind it.
//
// Two kinds of index:
//   .bruteForce  — Lane A: kernel scan over ResidentVectorArray.
//                  Always available. Binary-lane conformance oracle.
//                  The exact float-lane path is FloatBruteForceIndex.
//   .mih         — Lane B: Multi-Index Hashing, exact Hamming KNN,
//                  sub-linear (binary lane only).
//
// The protocol is intentionally thin: build + search + add + remove.
// Index-specific configuration (MIH band count m, ANN params) lives on
// the concrete conforming types, not on this protocol.
//
// Swift 6 strict concurrency: the protocol is Sendable. Conforming
// actors supply their own isolation boundary; conforming structs/
// classes must be explicitly Sendable.

import Foundation

// MARK: - IndexKind

/// Identifies which implementation backs a DenseIndex.
///
/// Consumers that need to gate behaviour on the implementation type
/// (e.g. test code that picks brute-force as the oracle) use this
/// tag rather than type-casting, keeping the seam nominal.
public enum IndexKind: String, Sendable, Equatable {
    /// BruteForceIndex: kernel scan over ResidentVectorArray.
    /// The binary-lane conformance oracle. Always available.
    case bruteForce = "brute_force"

    /// MIHIndex: Multi-Index Hashing, exact Hamming KNN, sub-linear.
    /// Binary lane only. Gated against bruteForce for correctness.
    case mih = "mih"
}

// MARK: - MetadataFilter

/// An optional pre-filter applied before distance ranking.
///
/// Lane F defines the type as a value that carries a modelID
/// constraint — the most common filter at the engine level. Future
/// lanes may extend this via an FT-1 update.
///
/// Nil means "no filter — scan all records for this index."
///
/// Thread-safety: value type, Sendable.
public struct MetadataFilter: Sendable, Equatable {
    /// If set, restrict the scan to records whose modelID equals this
    /// value. Matches VectorRecordKey.modelID exactly.
    public let modelID: String?

    /// If set, restrict the scan to records whose modelVersion equals
    /// this value. Both modelID and modelVersion must match when both
    /// are non-nil. Cross-version comparisons are forbidden per spec I-4.
    public let modelVersion: String?

    public init(modelID: String? = nil, modelVersion: String? = nil) {
        self.modelID = modelID
        self.modelVersion = modelVersion
    }

    /// Convenience: filter to a single (modelID, modelVersion) pair.
    public static func exact(modelID: String, modelVersion: String) -> MetadataFilter {
        MetadataFilter(modelID: modelID, modelVersion: modelVersion)
    }

    /// Apply this filter to a VectorRecordKey. Returns true if the
    /// key passes (i.e. should be included in the scan).
    ///
    /// Nil fields are wildcards: a nil modelID matches any modelID.
    public func accepts(_ key: VectorRecordKey) -> Bool {
        if let required = modelID, key.modelID != required { return false }
        if let required = modelVersion, key.modelVersion != required { return false }
        return true
    }
}

// MARK: - DenseIndex protocol

/// The engine seam: pluggable dense index over a ResidentVectorArray.
///
/// BruteForceIndex (Lane A) and MIHIndex (Lane B) conform to this
/// protocol. Callers that hold a `DenseIndex` reference are
/// lane-agnostic.
///
/// Conforming types are free to be actors or structs; the protocol
/// itself is `Sendable`-constrained so it can cross actor boundaries.
///
/// Correctness contract (arch spec §3.1):
///   - BruteForceIndex is the oracle. MIH results are gated against
///     BruteForce in conformance tests.
///   - Distance on the binary lane is computed ONLY by SubstrateKernel.
public protocol DenseIndex: Sendable {

    /// The kind of implementation backing this index.
    var kind: IndexKind { get }

    /// (Re-)build the index from a resident array.
    ///
    /// Implementations must be able to call `build` multiple times;
    /// the second call replaces the current index state. This is the
    /// warm-start path when the database is reopened.
    ///
    /// Complexity: O(n) for brute-force (index = array); O(n·m) for MIH.
    func build(from array: ResidentVectorArray) async

    /// k-nearest neighbours by DenseMetric, optionally filtered.
    ///
    /// Returns up to k DenseHit values sorted by rawDistance ascending,
    /// with ties broken by key.itemID ascending per the universal
    /// tie-break rule (retrieval algorithms reference §0.3).
    ///
    /// - Parameters:
    ///   - probe: the query vector. Must have the same kind and dim
    ///     as the vectors in this index, or the call throws
    ///     VectorKitError.invalidPayload.
    ///   - metric: the distance metric. Must be compatible with the
    ///     probe's kind (binary metric for binary payloads, float
    ///     metric for float payloads).
    ///   - k: maximum number of results. May return fewer if the
    ///     index contains fewer live records after filtering.
    ///   - filter: optional metadata pre-filter. Nil means no filter.
    func search(
        probe: VectorPayload,
        metric: DenseMetric,
        k: Int,
        filter: MetadataFilter?
    ) async throws -> [DenseHit]

    /// Add one vector record to the index.
    ///
    /// Additive-only: if a record with the same key already exists,
    /// the behaviour is implementation-defined (brute-force overwrites;
    /// MIH may require remove + insert). The ResidentArrayStore (Lane A)
    /// is responsible for ensuring uniqueness before calling add.
    func add(key: VectorRecordKey, vector: VectorPayload) async throws

    /// Remove the record identified by key from the index.
    ///
    /// No-op if the key is not present. After removal the slot is
    /// tombstoned; it is excluded from future searches until compaction.
    func remove(key: VectorRecordKey) async throws
}
