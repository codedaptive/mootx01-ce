// ResidentArrayStore.swift
//
// Lane A — packed on-disk .vec sidecar format, mmap load, write,
// append, tombstone, and compaction.
//
// The ResidentArrayStore is the bridge between the SQLite `vectors`
// table (source of truth) and the ResidentVectorArray that the
// BruteForceIndex (and MIH) scan. Its job:
//
//   • Maintain a packed, fixed-stride contiguous byte file (§4.2)
//     so that loading the array is a single OS read (or mmap),
//     not N per-row SQLite fetches.
//   • Expose a ResidentVectorArray to the search engine via snapshot().
//   • Accept append / tombstone operations that update both the
//     in-memory array and the sidecar atomically enough for crash
//     recovery (the SQLite table is always the authoritative source
//     of truth; the sidecar can be regenerated from it).
//   • Compact (rewrite) the sidecar when the tombstone ratio exceeds
//     a configurable threshold.
//
// On-disk format (arch spec §4.2):
//
//   [ magic:   4 bytes  = 0x56 0x45 0x43 0x31 ("VEC1") ]
//   [ version: 2 bytes  = 0x00 0x02 (little-endian)    ]
//   [ kind:    1 byte   = VectorKind raw value          ]
//   [ stride:  4 bytes  (little-endian UInt32)          ]
//   [ count:   4 bytes  (little-endian UInt32)          ]
//   [ live_count: 4 bytes (little-endian UInt32)        ]
//   [ tombstone_words: 4 bytes (little-endian UInt32, number of UInt64 words) ]
//   [ tombstones: tombstone_words × 8 bytes (UInt64 LE)  ]
//   [ vectors: count × stride bytes, contiguous         ]
//   [ keys:    count × variable-length records          ]
//     Key record: 4B item_id_len | item_id_bytes
//               | 4B vector_index (LE UInt32)
//               | 4B model_id_len | model_id_bytes
//               | 4B model_version_len | model_version_bytes
//   [ model_partition_index: 4B count | (key_len | key_bytes | 4B start | 4B end) * ]
//
// Endianness: all multi-byte integers are little-endian. This is a
// fixed, documented format choice (arch spec §4.3 byte-identity across
// Apple and Linux hosts).
//
// mmap load: on Apple platforms, Swift Data(contentsOf:.mappedIfSafe)
// is used to memory-map the sidecar read-only. On platforms where mmap
// is unavailable, a heap copy is used instead. Both paths produce
// bit-identical scan results; mmap is an optimisation, not a semantic
// (arch spec §4.3).
//
// The SQLite `vectors` table is always the source of truth. The sidecar
// is a regenerable cache. The ResidentArrayStore exposes
// `rebuild(from:)` to regenerate the sidecar from the table when
// needed (e.g. after crash recovery or first open).
//
// WRITE-AMORTISATION POLICY (TASK #24, import/migration-scale ingestion):
//   The per-row sidecar rewrite was O(N) bytes per write, so a bulk import
//   of N vectors cost O(N²) bytes written. Two amortised paths replace it:
//
//   • appendBatch(records:) — extends the in-memory array with all N records
//     in one pass and writes the sidecar EXACTLY ONCE. Bulk import drives
//     this, so a batch of N costs one sidecar write, not N.
//
//   • appendDeferred(key:bytes:) — the single-add write-behind path. It
//     mutates the in-memory array and sets `isDirty` WITHOUT writing the
//     sidecar. The caller (VectorStore) flushes via `flush()` at a quiesce
//     point (close, explicit flush, or a batch boundary). A process killed
//     before the flush loses only the sidecar cache: the `vectors` table
//     still holds every row, and the next open detects the live-count
//     mismatch and rebuilds the sidecar from the table. Crash safety is
//     therefore unchanged — the table remains the single durable source.
//
//   `append(key:bytes:)` (immediate-write) is retained for callers that
//   want eager persistence per write.
//
// Thread-safety: ResidentArrayStore is an actor. All sidecar I/O and
// in-memory array mutations are serialised through the actor.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "VectorKit")

// MARK: - Sidecar format constants

/// On-disk magic bytes for the .vec sidecar. "VEC1" in ASCII.
let kVecMagic: [UInt8] = [0x56, 0x45, 0x43, 0x31]

/// On-disk format version. Little-endian UInt16.
///
/// Version 0x0002: adds a `live_count` field (LE UInt32) immediately
/// after `count` and before `tombstone_words`. The field is written on
/// save but not used on load — on load the live count is recomputed
/// from the tombstone bitmap (`ResidentVectorArray.liveCount`) so a
/// stale or hand-written value cannot corrupt search results. This
/// matches the Rust sidecar format byte-for-byte (arch spec §4.3). No
/// installed sidecars exist at version 0x0001; the old bytes are rejected
/// by `parseSidecar`.
let kVecVersion: UInt16 = 0x0002

/// Threshold: when the ratio (tombstoned / total) exceeds this value,
/// compaction is triggered automatically on the next write. Configurable
/// per store instance.
public let kDefaultTombstoneCompactionThreshold: Double = 0.25

// MARK: - ResidentArrayStore

/// Manages the packed `.vec` sidecar file and the in-memory
/// ResidentVectorArray it backs.
///
/// Consumers of the search engine hold a reference to a BruteForceIndex
/// (or MIHIndex) and call `build(from:)` with the array vended by this
/// store's `snapshot()` method. The store is the single owner of the
/// mutable array; the indexes hold read-only snapshots.
///
/// Design principle: the store is not a search engine. It stores bytes
/// and vends arrays. The BruteForceIndex does the scanning.
public actor ResidentArrayStore {

    // MARK: - Configuration

    /// URL of the `.vec` sidecar file on disk.
    public let sidecarURL: URL

    /// The compaction threshold: when (tombstoned / total) > threshold,
    /// compact() is called automatically after the next write.
    public let compactionThreshold: Double

    // MARK: - State

    /// The current in-memory resident array.
    private var array: ResidentVectorArray

    /// Count of on-disk sidecar writes performed in this store's lifetime.
    ///
    /// Incremented once per `writeSidecar` call (rebuild, append, appendBatch,
    /// tombstone, compact). Exposed for test assertions only: the
    /// import-scale regression test asserts a bulk ingest of N vectors costs
    /// O(batches) sidecar writes, not O(N). Callers must not drive application
    /// logic from this value.
    private(set) var sidecarWriteCount: Int = 0

    /// True when the in-memory array has diverged from the on-disk sidecar.
    ///
    /// Set by `appendDeferred` (write-behind single-add path) and cleared by
    /// `flush`. Crash safety is unaffected: the SQLite `vectors` table is the
    /// durable source of truth, and `VectorStore._ensureIndexBuilt` rebuilds
    /// the sidecar from the table whenever the sidecar live_count disagrees
    /// with the table row count. A dirty in-memory array that is never flushed
    /// (process killed mid-batch) is simply discarded on the next open; the
    /// table-rebuild path reconstructs it. See the file header policy note.
    private(set) var isDirty: Bool = false

    // MARK: - Init

    /// Create or open a ResidentArrayStore backed by `sidecarURL`.
    ///
    /// If the sidecar file exists and has a valid header, it is loaded
    /// (mmap on Apple). If the file does not exist, the store starts
    /// empty and will write a new sidecar on the first `append`.
    ///
    /// - Parameters:
    ///   - sidecarURL: path to the .vec file.
    ///   - kind: the VectorKind for vectors in this store.
    ///   - stride: bytes per vector slot (32 for binary).
    ///   - compactionThreshold: tombstone ratio that triggers compaction.
    public init(
        sidecarURL: URL,
        kind: VectorKind = .binary,
        stride: UInt32 = 32,
        compactionThreshold: Double = kDefaultTombstoneCompactionThreshold
    ) {
        self.sidecarURL = sidecarURL
        self.compactionThreshold = compactionThreshold
        // Start with an empty array; load() must be called to hydrate.
        self.array = ResidentVectorArray.empty(kind: kind, stride: stride)
    }

    // MARK: - Public API

    /// Load (or reload) the sidecar from disk.
    ///
    /// If the sidecar file is absent or invalid, the in-memory array is
    /// reset to empty. Call this once at startup before vending snapshots.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            log.info("ResidentArrayStore: no sidecar at \(self.sidecarURL.lastPathComponent); starting empty")
            return
        }
        do {
            let loaded = try ResidentArrayStore.readSidecar(from: sidecarURL)
            self.array = loaded
            isDirty = false // in-memory array now matches disk
            log.info("ResidentArrayStore: loaded \(loaded.count) vectors from sidecar")
        } catch {
            log.error("ResidentArrayStore: sidecar load failed (\(error)); starting empty")
            // An invalid sidecar does not crash the store. The table is the
            // source of truth; rebuild(from:) will regenerate the sidecar.
            // Reset to the correct kind/stride but keep the store open.
        }
    }

    /// Rebuild the entire sidecar from a sorted [(key, bytes)] list.
    ///
    /// Called when the sidecar is absent, corrupted, or out of date with
    /// the SQLite `vectors` table. The input must be sorted by key
    /// (VectorRecordKey natural order) so the model partition index is
    /// correct.
    ///
    /// - Parameter records: sorted (key, 32-byte vector bytes) pairs.
    public func rebuild(from records: [(key: VectorRecordKey, bytes: [UInt8])]) throws {
        let newArray = Self.buildArray(from: records, kind: array.kind, stride: array.stride)
        try persist(newArray)
        log.info("ResidentArrayStore: rebuilt sidecar with \(records.count) records")
    }

    /// Persist `newArray` to the sidecar and adopt it as the current array.
    ///
    /// The single internal funnel for every on-disk write: it increments
    /// `sidecarWriteCount` (test instrumentation) and clears `isDirty`
    /// because the in-memory array now matches the file. All mutators that
    /// write eagerly route through here so the write count is exact.
    private func persist(_ newArray: ResidentVectorArray) throws {
        try Self.writeSidecar(newArray, to: sidecarURL)
        self.array = newArray
        sidecarWriteCount += 1
        isDirty = false
    }

    /// Return a snapshot of the current in-memory array.
    ///
    /// The caller (typically BruteForceIndex or MIHIndex) calls
    /// `build(from:)` on the snapshot to make it the scan target.
    /// The snapshot is value-typed and safe to pass across actor
    /// boundaries.
    public func snapshot() -> ResidentVectorArray {
        array
    }

    /// Append a new (key, bytes) pair to the store.
    ///
    /// Updates both the in-memory array and the on-disk sidecar.
    /// If the tombstone ratio after the append exceeds the compaction
    /// threshold, compact() is called automatically.
    ///
    /// - Parameters:
    ///   - key: the VectorRecordKey for this record.
    ///   - bytes: the raw vector bytes (must match array.stride).
    public func append(key: VectorRecordKey, bytes: [UInt8]) throws {
        guard bytes.count == Int(array.stride) else {
            throw VectorKitError.invalidPayload(
                "ResidentArrayStore.append: bytes.count \(bytes.count) != stride \(array.stride)")
        }

        let newArray = Self.appendingArray(to: array, key: key, bytes: bytes)
        try persist(newArray)

        // Auto-compact if the tombstone ratio exceeds the threshold.
        if tombstoneRatio() > compactionThreshold {
            try compact()
        }
    }

    /// Append a new (key, bytes) pair WITHOUT writing the sidecar.
    ///
    /// The write-behind single-add path (TASK #24). Mutates the in-memory
    /// array and sets `isDirty`; the caller must `flush()` at a quiesce
    /// point to persist. Used by `VectorStore.addPayload` so a single write
    /// no longer rewrites the whole sidecar. Crash safety is preserved by
    /// the table-rebuild path (see the file header policy note).
    ///
    /// Auto-compaction is NOT triggered here: it would force a sidecar
    /// write, defeating the deferral. Compaction runs on the next eager
    /// write (append / appendBatch / tombstone) or on `flush()`-then-write.
    ///
    /// - Parameters:
    ///   - key: the VectorRecordKey for this record.
    ///   - bytes: the raw vector bytes (must match array.stride).
    public func appendDeferred(key: VectorRecordKey, bytes: [UInt8]) throws {
        guard bytes.count == Int(array.stride) else {
            throw VectorKitError.invalidPayload(
                "ResidentArrayStore.appendDeferred: bytes.count \(bytes.count) != stride \(array.stride)")
        }
        self.array = Self.appendingArray(to: array, key: key, bytes: bytes)
        isDirty = true
    }

    /// Append N (key, bytes) pairs in one pass, writing the sidecar EXACTLY
    /// ONCE at the end.
    ///
    /// The import-scale bulk path (TASK #24). A batch of N records extends
    /// storage, keys, and the tombstone bitset once, rebuilds the partition
    /// index once, and performs a single sidecar write — so a bulk import of
    /// N vectors costs O(batches) sidecar writes, not O(N).
    ///
    /// Tombstoning of prior slots for replaced keys is the caller's
    /// responsibility (VectorStore tombstones replaced keys before the
    /// batch append, mirroring the table's ON CONFLICT UPDATE).
    ///
    /// - Parameter records: (key, vector bytes) pairs. Each must match stride.
    public func appendBatch(records: [(key: VectorRecordKey, bytes: [UInt8])]) throws {
        guard !records.isEmpty else { return }

        var newStorage = array.storage
        newStorage.reserveCapacity(newStorage.count + records.count * Int(array.stride))
        var newKeys = array.keys
        newKeys.reserveCapacity(newKeys.count + records.count)

        for r in records {
            guard r.bytes.count == Int(array.stride) else {
                throw VectorKitError.invalidPayload(
                    "ResidentArrayStore.appendBatch: bytes.count \(r.bytes.count) != stride \(array.stride)")
            }
            newStorage.append(contentsOf: r.bytes)
            newKeys.append(r.key)
        }

        let newCount = UInt32(newKeys.count)
        var newTombstones = array.tombstones
        let wordsNeeded = (Int(newCount) + 63) / 64
        while newTombstones.count < wordsNeeded { newTombstones.append(0) }

        let newPartitions = Self.buildPartitions(keys: newKeys, tombstones: newTombstones)
        let newArray = ResidentVectorArray(
            kind: array.kind,
            stride: array.stride,
            count: newCount,
            storage: newStorage,
            keys: newKeys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )

        try persist(newArray)

        if tombstoneRatio() > compactionThreshold {
            try compact()
        }
    }

    /// Flush a pending write-behind mutation to the sidecar.
    ///
    /// No-op when the in-memory array already matches the file (`isDirty`
    /// false). Called by `VectorStore` at quiesce points (explicit flush,
    /// store close, batch boundary). After flush the sidecar is current and
    /// `isDirty` is cleared. Auto-compaction is evaluated after the flush so
    /// deferred appends still get compacted when the tombstone ratio is high.
    public func flush() throws {
        guard isDirty else { return }
        try persist(array)
        if tombstoneRatio() > compactionThreshold {
            try compact()
        }
    }

    /// Build a new array that appends one (key, bytes) slot to `base`.
    ///
    /// Shared by the eager `append` and the deferred `appendDeferred` paths
    /// so both produce byte-identical layouts. Does not write the sidecar.
    private static func appendingArray(
        to base: ResidentVectorArray,
        key: VectorRecordKey,
        bytes: [UInt8]
    ) -> ResidentVectorArray {
        var newStorage = base.storage
        newStorage.append(contentsOf: bytes)
        var newKeys = base.keys
        newKeys.append(key)
        let newCount = UInt32(newKeys.count)
        var newTombstones = base.tombstones
        let wordsNeeded = (Int(newCount) + 63) / 64
        while newTombstones.count < wordsNeeded { newTombstones.append(0) }
        let newPartitions = buildPartitions(keys: newKeys, tombstones: newTombstones)
        return ResidentVectorArray(
            kind: base.kind,
            stride: base.stride,
            count: newCount,
            storage: newStorage,
            keys: newKeys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )
    }

    /// Tombstone the record identified by `key`.
    ///
    /// The slot is marked deleted in both memory and the sidecar. The
    /// storage bytes remain until compaction. No-op if `key` is absent.
    public func tombstone(key: VectorRecordKey) throws {
        var newTombstones = array.tombstones
        var changed = false
        for slotIdx in 0..<Int(array.count) where array.keys[slotIdx] == key {
            Self.setTombstoneBit(&newTombstones, slot: slotIdx)
            changed = true
        }
        guard changed else { return }

        let newPartitions = Self.buildPartitions(keys: array.keys, tombstones: newTombstones)
        let newArray = ResidentVectorArray(
            kind: array.kind,
            stride: array.stride,
            count: array.count,
            storage: array.storage,
            keys: array.keys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )
        try persist(newArray)

        if tombstoneRatio() > compactionThreshold {
            try compact()
        }
    }

    /// Tombstone every record matching any key in `keys` WITHOUT writing.
    ///
    /// The batch counterpart of `tombstone`. Used by `VectorStore` before a
    /// bulk `appendBatch` to retire prior slots for replaced keys in one
    /// pass — mirroring the table's ON CONFLICT UPDATE — without N sidecar
    /// rewrites. The append that follows performs the single sidecar write.
    /// No-op if none of the keys are present.
    public func tombstoneDeferred(keys: Set<VectorRecordKey>) async {
        guard !keys.isEmpty else { return }
        var newTombstones = array.tombstones
        var changed = false
        for slotIdx in 0..<Int(array.count) where keys.contains(array.keys[slotIdx]) {
            Self.setTombstoneBit(&newTombstones, slot: slotIdx)
            changed = true
        }
        guard changed else { return }
        let newPartitions = Self.buildPartitions(keys: array.keys, tombstones: newTombstones)
        self.array = ResidentVectorArray(
            kind: array.kind,
            stride: array.stride,
            count: array.count,
            storage: array.storage,
            keys: array.keys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )
        isDirty = true
    }

    /// Rewrite the sidecar dropping all tombstoned slots.
    ///
    /// The compacted array is sorted by key (VectorRecordKey natural
    /// order) so the output is deterministic and reproducible given
    /// identical input (arch spec §4.2: "deterministic output order").
    /// After compaction the tombstone ratio is 0.
    public func compact() throws {
        // Gather live records and sort by key for deterministic output.
        var live: [(key: VectorRecordKey, bytes: [UInt8])] = []
        live.reserveCapacity(Int(array.count))
        for slotIdx in 0..<Int(array.count) {
            guard !array.isTombstoned(slotIdx) else { continue }
            guard let bytes = array.vectorBytes(at: slotIdx) else { continue }
            live.append((key: array.keys[slotIdx], bytes: bytes))
        }
        live.sort { $0.key < $1.key }

        let compacted = Self.buildArray(from: live, kind: array.kind, stride: array.stride)
        try persist(compacted)
        log.info("ResidentArrayStore: compacted to \(live.count) live vectors")
    }

    // MARK: - Private helpers — tombstone ratio

    /// The fraction of slots that are tombstoned. Used to gate auto-compaction.
    private func tombstoneRatio() -> Double {
        let total = Int(array.count)
        guard total > 0 else { return 0 }
        var dead = 0
        for slotIdx in 0..<total {
            if array.isTombstoned(slotIdx) { dead += 1 }
        }
        return Double(dead) / Double(total)
    }

    // MARK: - Private helpers — bitset

    /// Set tombstone bit for `slot`. UInt64 storage: clean unsigned
    /// bit ops without reinterpret casts; matches BruteForceIndex helper
    /// and the ResidentVectorArray wire format (arch spec §4.2).
    static func setTombstoneBit(_ words: inout [UInt64], slot: Int) {
        let w = slot / 64
        let b = slot % 64
        while words.count <= w { words.append(0) }
        words[w] |= (UInt64(1) << b)
    }

    // MARK: - Private helpers — partition building

    /// Build sorted model partitions from keys + tombstones. Mirrors
    /// BruteForceIndex.buildPartitions for consistency.
    static func buildPartitions(
        keys: [VectorRecordKey],
        tombstones: [UInt64]
    ) -> [ModelPartitionEntry] {
        var minIdx: [String: Int] = [:]
        var maxIdx: [String: Int] = [:]
        for (idx, key) in keys.enumerated() {
            let w = idx / 64
            let b = idx % 64
            let dead: Bool = w < tombstones.count
                && (tombstones[w] >> b) & 1 == 1
            if !dead {
                let mid = key.modelID
                if minIdx[mid] == nil || idx < minIdx[mid]! { minIdx[mid] = idx }
                if maxIdx[mid] == nil || idx > maxIdx[mid]! { maxIdx[mid] = idx }
            }
        }
        return minIdx.keys.sorted().compactMap { modelID in
            guard let lo = minIdx[modelID], let hi = maxIdx[modelID] else { return nil }
            return ModelPartitionEntry(modelID: modelID, range: lo..<(hi + 1))
        }
    }

    // MARK: - Private helpers — array construction

    /// Build a ResidentVectorArray from a list of (key, bytes) records.
    static func buildArray(
        from records: [(key: VectorRecordKey, bytes: [UInt8])],
        kind: VectorKind,
        stride: UInt32
    ) -> ResidentVectorArray {
        let count = UInt32(records.count)
        var storageBytes = [UInt8]()
        storageBytes.reserveCapacity(records.count * Int(stride))
        var keys = [VectorRecordKey]()
        keys.reserveCapacity(records.count)

        for r in records {
            storageBytes.append(contentsOf: r.bytes)
            keys.append(r.key)
        }

        // All slots are live (no tombstones in a freshly-built array).
        let tombstones = [UInt64](repeating: 0, count: (records.count + 63) / 64)
        let partitions = buildPartitions(keys: keys, tombstones: tombstones)

        return ResidentVectorArray(
            kind: kind,
            stride: stride,
            count: count,
            storage: Data(storageBytes),
            keys: keys,
            modelPartitions: partitions,
            tombstones: tombstones
        )
    }

    // MARK: - Sidecar I/O

    /// Write a ResidentVectorArray to the .vec sidecar format.
    ///
    /// Format (all integers little-endian):
    ///   magic(4) | version(2) | kind(1) | stride(4) | count(4)
    ///   | live_count(4) | tombstone_words(4) | tombstones(8×T)
    ///   | vectors(count×stride)
    ///   | keys(variable, see encodeKey)
    ///   | partition_index(variable, see encodePartitions)
    ///
    /// The format is byte-identical across Apple (Swift) and Linux/Windows
    /// (Rust) for the same logical array (arch spec §4.3).
    static func writeSidecar(_ arr: ResidentVectorArray, to url: URL) throws {
        var data = Data()
        data.reserveCapacity(128 + arr.storage.count)

        // Magic + version + kind + stride + count + live_count
        data.append(contentsOf: kVecMagic)
        data.appendLE16(kVecVersion)
        data.append(arr.kind.rawValue)
        data.appendLE32(arr.stride)
        data.appendLE32(arr.count)
        // live_count: non-tombstoned slot count. Lets VectorStore stale
        // detection compare live-vs-live without a bitmap walk (format
        // 0x0002, byte-identical with the Rust sidecar).
        data.appendLE32(arr.liveCount)

        // Tombstone block
        let tombstoneWords = UInt32(arr.tombstones.count)
        data.appendLE32(tombstoneWords)
        for word in arr.tombstones {
            data.appendLE64(word)
        }

        // Vectors block (packed, fixed-stride)
        data.append(contentsOf: arr.storage)

        // Keys block
        for key in arr.keys {
            encodeKey(key, into: &data)
        }

        // Model partition index
        encodePartitions(arr.modelPartitions, into: &data)

        // Atomic write: write to a temp file then rename, so a crash
        // during write does not leave a corrupted sidecar.
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // Replace destination atomically.
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// Read and parse a .vec sidecar file, returning a ResidentVectorArray.
    ///
    /// Uses `Data(contentsOf:options:.mappedIfSafe)` on Apple platforms,
    /// which memory-maps the file read-only. Falls back to a heap read if
    /// mmap is unavailable. Both produce bit-identical arrays (arch spec §4.3).
    static func readSidecar(from url: URL) throws -> ResidentVectorArray {
        // .mappedIfSafe uses mmap when the OS supports it; otherwise it
        // reads into a heap buffer. The resulting Data has the same bytes
        // either way — mmap is transparent to the caller.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parseSidecar(data)
    }

    /// Parse the raw .vec bytes into a ResidentVectorArray.
    ///
    /// This is the canonical parser used by both the mmap and heap paths.
    /// It is `internal` so tests can exercise it directly without touching
    /// the filesystem.
    static func parseSidecar(_ data: Data) throws -> ResidentVectorArray {
        var offset = 0

        // --- Magic ---
        guard data.count >= 4 else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: sidecar too short for magic")
        }
        let magic = Array(data[0..<4])
        guard magic == kVecMagic else {
            throw VectorKitError.decodingFailure(
                "ResidentArrayStore: bad magic \(magic); expected VEC1")
        }
        offset = 4

        // --- Version ---
        // readLE16 subscripts data[offset] and data[offset+1] without its own
        // bounds check, so we guard that 2 bytes remain before calling it.
        guard data.count >= offset + 2 else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated at version field")
        }
        let version = data.readLE16(at: offset)
        offset += 2
        guard version == kVecVersion else {
            throw VectorKitError.decodingFailure(
                "ResidentArrayStore: unsupported version \(version); expected \(kVecVersion)")
        }

        // --- Kind ---
        guard offset < data.count else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated at kind")
        }
        let kindRaw = data[offset]; offset += 1
        guard let kind = VectorKind(rawValue: kindRaw) else {
            throw VectorKitError.decodingFailure(
                "ResidentArrayStore: unknown kind byte \(kindRaw)")
        }

        // --- Stride ---
        // readLE32 subscripts four bytes without its own bounds check.
        guard data.count >= offset + 4 else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated at stride field")
        }
        let stride = data.readLE32(at: offset); offset += 4

        // --- Count ---
        guard data.count >= offset + 4 else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated at count field")
        }
        let count = data.readLE32(at: offset); offset += 4

        // --- Live count (format 0x0002) ---
        // Read and discard: the authoritative live count is recomputed
        // from the tombstone bitmap after load (ResidentVectorArray.liveCount)
        // so a stale header value can never affect search results. The field
        // exists only to make stale detection an O(1) header read on the
        // happy path; it is cross-checked against the bitmap in tests.
        guard data.count >= offset + 4 else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated at live_count field")
        }
        _ = data.readLE32(at: offset); offset += 4

        // --- Tombstones ---
        guard data.count >= offset + 4 else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated at tombstone_words field")
        }
        let tombstoneWords = data.readLE32(at: offset); offset += 4
        // Guard against overflow when computing tombstone block byte size:
        // tombstoneWords is UInt32 so the max product is ~34 GB — safe in
        // Int64 but not necessarily in Int on a 32-bit host.  Use a checked
        // multiply so a malformed sidecar can't cause overflow.
        let tombstoneBlockBytes: Int
        let (tsBytes, tsOverflow) = Int(tombstoneWords).multipliedReportingOverflow(by: 8)
        guard !tsOverflow else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: tombstone block size overflows")
        }
        tombstoneBlockBytes = tsBytes
        guard offset + tombstoneBlockBytes <= data.count else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated in tombstone block")
        }
        var tombstones = [UInt64]()
        tombstones.reserveCapacity(Int(tombstoneWords))
        for _ in 0..<Int(tombstoneWords) {
            // Each 8-byte readLE64 is safe: the tombstoneBlockBytes guard above
            // ensures the entire tombstone block is within data.
            let word = data.readLE64(at: offset); offset += 8
            tombstones.append(word)
        }

        // --- Vectors block ---
        // Guard against overflow in count * stride before checking bounds.
        // Both count and stride are UInt32; their product as Int can overflow
        // on 32-bit platforms or with pathological values.
        let vectorsBytes: Int
        let (vb, vbOverflow) = Int(count).multipliedReportingOverflow(by: Int(stride))
        guard !vbOverflow else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: vectors block size overflows")
        }
        vectorsBytes = vb
        guard offset + vectorsBytes <= data.count else {
            throw VectorKitError.decodingFailure("ResidentArrayStore: truncated in vectors block")
        }
        // ADR-026: pass the Data slice directly instead of copying into
        // a heap-allocated [UInt8]. When the sidecar was loaded via
        // .mappedIfSafe, this keeps the vector bytes mmap-backed — the OS
        // page cache manages residency instead of a 2GB+ malloc. The Data
        // subscript range produces a zero-copy slice sharing the mmap.
        let vectorData = data[offset..<(offset + vectorsBytes)]
        offset += vectorsBytes

        // --- Keys block ---
        // ADR-026 string interning: on a 200K-vector estate with 1 model,
        // decoding modelID + modelVersion per key allocates 400K identical
        // String heap objects (~500MB). Interning collapses these to one
        // shared instance per unique string. Swift String is CoW, so
        // assigning the interned reference does not copy — all 200K keys
        // hold ONE pointer to the same backing storage.
        var stringIntern: [String: String] = [:]
        func intern(_ s: String) -> String {
            if let existing = stringIntern[s] { return existing }
            stringIntern[s] = s
            return s
        }
        var keys = [VectorRecordKey]()
        keys.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            let (key, bytesRead) = try decodeKey(data, at: offset, intern: intern)
            keys.append(key)
            offset += bytesRead
        }

        // --- Partition index ---
        let (partitions, partBytesRead) = try decodePartitions(data, at: offset)
        offset += partBytesRead
        _ = offset // silence unused-variable warning

        return ResidentVectorArray(
            kind: kind,
            stride: stride,
            count: count,
            storage: vectorData,
            keys: keys,
            modelPartitions: partitions,
            tombstones: tombstones
        )
    }

    // MARK: - Key encode/decode

    /// Encode a VectorRecordKey as:
    ///   4B LE length of item_id UTF-8 | item_id bytes
    ///   4B LE vector_index
    ///   4B LE length of model_id UTF-8 | model_id bytes
    ///   4B LE length of model_version UTF-8 | model_version bytes
    static func encodeKey(_ key: VectorRecordKey, into data: inout Data) {
        let itemIDBytes = Array(key.itemID.utf8)
        data.appendLE32(UInt32(itemIDBytes.count))
        data.append(contentsOf: itemIDBytes)
        data.appendLE32(key.vectorIndex)
        let modelIDBytes = Array(key.modelID.utf8)
        data.appendLE32(UInt32(modelIDBytes.count))
        data.append(contentsOf: modelIDBytes)
        let modelVersionBytes = Array(key.modelVersion.utf8)
        data.appendLE32(UInt32(modelVersionBytes.count))
        data.append(contentsOf: modelVersionBytes)
    }

    /// Decode a VectorRecordKey from `data` at `offset`.
    /// Returns (key, bytes consumed).
    /// Decode one key record from the sidecar binary format.
    ///
    /// The `intern` closure deduplicates modelID and modelVersion strings
    /// (ADR-026): on a typical estate all 200K keys share one modelID and
    /// one modelVersion. Without interning, each key allocates its own
    /// String heap object for those fields (~500MB on a 50K estate).
    /// itemID is NOT interned — it's unique per slot.
    static func decodeKey(
        _ data: Data, at offset: Int,
        intern: ((String) -> String)? = nil
    ) throws -> (VectorRecordKey, Int) {
        var pos = offset

        func readString() throws -> String {
            guard pos + 4 <= data.count else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodeKey: truncated at string length (pos=\(pos))")
            }
            let len = Int(data.readLE32(at: pos)); pos += 4
            guard pos + len <= data.count else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodeKey: truncated in string body len=\(len) pos=\(pos)")
            }
            guard let s = String(bytes: data[pos..<(pos + len)], encoding: .utf8) else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodeKey: invalid UTF-8 at pos=\(pos)")
            }
            pos += len
            return s
        }

        let itemID = try readString()
        guard pos + 4 <= data.count else {
            throw VectorKitError.decodingFailure(
                "ResidentArrayStore.decodeKey: truncated at vectorIndex")
        }
        let vectorIndex = data.readLE32(at: pos); pos += 4
        let rawModelID = try readString()
        let rawModelVersion = try readString()

        // Intern modelID/modelVersion — these repeat for every slot in
        // the same partition. itemID is unique, not interned.
        let modelID = intern?(rawModelID) ?? rawModelID
        let modelVersion = intern?(rawModelVersion) ?? rawModelVersion

        let key = VectorRecordKey(itemID: itemID,
                                  vectorIndex: vectorIndex,
                                  modelID: modelID,
                                  modelVersion: modelVersion)
        return (key, pos - offset)
    }

    // MARK: - Partition index encode/decode

    /// Encode the model partition index as:
    ///   4B LE entry count
    ///   For each entry:
    ///     4B LE model_id length | model_id bytes
    ///     4B LE range.lowerBound | 4B LE range.upperBound
    static func encodePartitions(_ partitions: [ModelPartitionEntry], into data: inout Data) {
        data.appendLE32(UInt32(partitions.count))
        for p in partitions {
            let midBytes = Array(p.modelID.utf8)
            data.appendLE32(UInt32(midBytes.count))
            data.append(contentsOf: midBytes)
            data.appendLE32(UInt32(p.range.lowerBound))
            data.appendLE32(UInt32(p.range.upperBound))
        }
    }

    /// Decode the partition index. Returns (partitions, bytes consumed).
    static func decodePartitions(
        _ data: Data,
        at offset: Int
    ) throws -> ([ModelPartitionEntry], Int) {
        var pos = offset
        guard pos + 4 <= data.count else {
            // An absent partition block means zero partitions (old or
            // empty file). This is not an error.
            return ([], 0)
        }
        let count = Int(data.readLE32(at: pos)); pos += 4
        var partitions = [ModelPartitionEntry]()
        partitions.reserveCapacity(count)
        for _ in 0..<count {
            guard pos + 4 <= data.count else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodePartitions: truncated at model_id length")
            }
            let midLen = Int(data.readLE32(at: pos)); pos += 4
            guard pos + midLen <= data.count else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodePartitions: truncated in model_id body")
            }
            guard let modelID = String(bytes: data[pos..<(pos + midLen)], encoding: .utf8) else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodePartitions: invalid UTF-8 model_id")
            }
            pos += midLen
            guard pos + 8 <= data.count else {
                throw VectorKitError.decodingFailure(
                    "ResidentArrayStore.decodePartitions: truncated at range bounds")
            }
            let lo = Int(data.readLE32(at: pos)); pos += 4
            let hi = Int(data.readLE32(at: pos)); pos += 4
            partitions.append(ModelPartitionEntry(modelID: modelID, range: lo..<hi))
        }
        return (partitions, pos - offset)
    }
}

// MARK: - Data little-endian helpers

extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8)  & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
    mutating func appendLE64(_ v: UInt64) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8)  & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 32) & 0xFF))
        append(UInt8((v >> 40) & 0xFF))
        append(UInt8((v >> 48) & 0xFF))
        append(UInt8((v >> 56) & 0xFF))
    }

    func readLE16(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return b0 | (b1 << 8)
    }
    func readLE32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    func readLE64(at offset: Int) -> UInt64 {
        let b0 = UInt64(self[offset])
        let b1 = UInt64(self[offset + 1])
        let b2 = UInt64(self[offset + 2])
        let b3 = UInt64(self[offset + 3])
        let b4 = UInt64(self[offset + 4])
        let b5 = UInt64(self[offset + 5])
        let b6 = UInt64(self[offset + 6])
        let b7 = UInt64(self[offset + 7])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
             | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)
    }
}
