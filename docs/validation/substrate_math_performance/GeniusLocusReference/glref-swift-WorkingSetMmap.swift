// WorkingSetMmap.swift
//
// Memory-mapped working set per cookbook § 4.2 and paper § 11.2.
//
// The substrate's hot working set is memory-mapped from a single
// page-aligned file on disk. The OS pages in and out as needed;
// the substrate reads bit-sliced tensor data through ordinary
// pointer access. This gives:
//
//   - zero-copy read access from CPU and Metal-compute kernels
//   - lazy paging: only touched pages occupy RAM
//   - durable on shutdown: the OS flushes dirty pages
//   - shareable read-only with the cognition tier (FP16 ANE path)
//
// File layout (cookbook § 4.2.3):
//
//   header   (page 0, 4 KiB):
//       magic 8B, version 4B, page_size 4B,
//       row_count 8B, field_count 8B, bits_per_field 8B,
//       slice_byte_size 8B, last_hlc 16B,
//       crc32 of header 4B, padding to 4096
//
//   slice 0  (pages 1..): bit-sliced tensor slice for bit 0
//   slice 1  (pages ...): bit-sliced tensor slice for bit 1
//   ...
//   slice 5  (final slices): bit-sliced tensor slice for bit 5
//
// Reference implementation: portable abstraction. Production
// uses mmap on Apple/Linux and CreateFileMapping on Windows;
// the reference uses ordinary file I/O so the conformance gate
// passes on platforms without mmap (the bit-identical output
// constraint applies to substrate operations, not their I/O
// backend).
//
// Used by:
//   § 4.2 cookbook   Mmap working set definition (this file)
//   § 11.2 paper     Memory layout details
//   § 4.3 cookbook   SQLite durability tail (consumer of header HLC)
//   § 15 cookbook    Dreaming daemon (flushes on schedule)

import Foundation

public struct WorkingSetHeader: Sendable {
    public static let magic: UInt64 = 0x474C4F435553574B   // "GLOCUSWK"
    public static let version: UInt32 = 1
    public static let pageSize: UInt32 = 4096
    public static let headerSize: Int = 4096

    public let rowCount: UInt64
    public let fieldCount: UInt64
    public let bitsPerField: UInt64
    public let sliceByteSize: UInt64
    public let lastHLC: HLC
    public let crc32: UInt32

    public init(rowCount: UInt64, fieldCount: UInt64,
                bitsPerField: UInt64, sliceByteSize: UInt64,
                lastHLC: HLC, crc32: UInt32) {
        self.rowCount = rowCount
        self.fieldCount = fieldCount
        self.bitsPerField = bitsPerField
        self.sliceByteSize = sliceByteSize
        self.lastHLC = lastHLC
        self.crc32 = crc32
    }
}

public final class WorkingSet {
    public private(set) var tensor: ThreeDBitTensor
    public private(set) var header: WorkingSetHeader
    private let path: URL

    public init(path: URL, rowCount: Int) throws {
        self.path = path
        self.tensor = ThreeDBitTensor(rowCount: rowCount)
        let sliceBytes = (rowCount * ThreeDBitTensor.fieldCount + 7) / 8
        self.header = WorkingSetHeader(rowCount: UInt64(rowCount),
                                       fieldCount: UInt64(ThreeDBitTensor.fieldCount),
                                       bitsPerField: UInt64(ThreeDBitTensor.bitsPerField),
                                       sliceByteSize: UInt64(sliceBytes),
                                       lastHLC: HLC.zero,
                                       crc32: 0)
    }

    /// Load from disk if file exists; create new if not.
    public static func openOrCreate(path: URL, rowCount: Int) throws -> WorkingSet {
        if FileManager.default.fileExists(atPath: path.path) {
            return try load(from: path)
        } else {
            return try WorkingSet(path: path, rowCount: rowCount)
        }
    }

    /// Persist the working set to disk. Writes header + all six
    /// slices in canonical layout.
    public func flush(at hlc: HLC) throws {
        var data = Data(capacity: Int(WorkingSetHeader.headerSize)
                                + tensor.byteSize)
        var headerBytes = Data(count: Int(WorkingSetHeader.headerSize))
        // Pack header
        headerBytes.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!
            ptr.storeBytes(of: WorkingSetHeader.magic.littleEndian,
                           toByteOffset: 0, as: UInt64.self)
            ptr.storeBytes(of: WorkingSetHeader.version.littleEndian,
                           toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: WorkingSetHeader.pageSize.littleEndian,
                           toByteOffset: 12, as: UInt32.self)
            ptr.storeBytes(of: UInt64(tensor.rowCount).littleEndian,
                           toByteOffset: 16, as: UInt64.self)
            ptr.storeBytes(of: UInt64(ThreeDBitTensor.fieldCount).littleEndian,
                           toByteOffset: 24, as: UInt64.self)
            ptr.storeBytes(of: UInt64(ThreeDBitTensor.bitsPerField).littleEndian,
                           toByteOffset: 32, as: UInt64.self)
            ptr.storeBytes(of: header.sliceByteSize.littleEndian,
                           toByteOffset: 40, as: UInt64.self)
            ptr.storeBytes(of: hlc.packed.littleEndian,
                           toByteOffset: 48, as: UInt64.self)
        }
        data.append(headerBytes)
        for slice in tensor.slices {
            data.append(contentsOf: slice)
        }
        try data.write(to: path, options: .atomic)
    }

    /// Load from disk, validating the header and reconstructing
    /// the bit-tensor from on-disk slices.
    static func load(from path: URL) throws -> WorkingSet {
        let data = try Data(contentsOf: path)
        guard data.count >= WorkingSetHeader.headerSize else {
            throw NSError(domain: "WorkingSetMmap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "file too small"])
        }
        let magic = data.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        guard magic == WorkingSetHeader.magic else {
            throw NSError(domain: "WorkingSetMmap", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bad magic"])
        }
        let rowCount = Int(data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 16, as: UInt64.self).littleEndian
        })
        let ws = try WorkingSet(path: path, rowCount: rowCount)
        let sliceBytes = Int(ws.header.sliceByteSize)
        var offset = WorkingSetHeader.headerSize
        for b in 0..<ThreeDBitTensor.bitsPerField {
            let slice = Array(data[offset..<offset + sliceBytes])
            ws.tensor.slices[b] = slice
            offset += sliceBytes
        }
        return ws
    }
}
