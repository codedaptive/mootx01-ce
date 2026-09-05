// BasisBlobFrame.swift
//
// The fixed prefix every provider basis and counts blob starts with:
//
//   MAGIC (4 ASCII bytes naming the provider) | FORMAT_VERSION (1 byte) | payload
//
// The codec that writes and reads these blobs lives in CorpusKitProviders
// (BasisCodec.swift / basis_codec.rs); CorpusKit core never interprets the
// payload. Core reads ONLY this five-byte frame, and only to compare a
// PERSISTED blob against the frame the CURRENT provider writes for the same
// magic. That comparison is how an estate written by an earlier codec is
// recognised at open: the persisted basis is not decoded as if it were the
// current one (the codec would refuse it), and it is not silently served —
// the slot opens untrained and the ordinary reconcile / upgrade retrain
// publishes a current basis over it.
//
// Rust twin: packages/kits/CorpusKit/rust/src/basis_blob_frame.rs

import Foundation

/// The five-byte basis/counts blob frame (magic + format version).
public enum BasisBlobFrame {

    /// Bytes in the frame: 4 magic bytes + 1 format-version byte.
    public static let length = 5

    /// The format-version byte of `blob`, or nil when the blob is too short
    /// to carry a frame.
    public static func formatVersion(of blob: Data) -> UInt8? {
        guard blob.count >= length else { return nil }
        return blob[blob.startIndex + 4]
    }

    /// The 4 magic bytes of `blob`, or nil when the blob is too short.
    public static func magic(of blob: Data) -> Data? {
        guard blob.count >= length else { return nil }
        return blob.prefix(4)
    }

    /// True when `persisted` carries the SAME magic as `current` but a
    /// DIFFERENT format version: a blob written by another codec generation
    /// for this provider. A blob too short to frame, or one whose magic
    /// differs (a keying error, not a version skew), is not "stale" — the
    /// decoder reports those as the corruption they are.
    public static func isStaleVersion(persisted: Data, current: Data) -> Bool {
        guard let persistedMagic = magic(of: persisted), let currentMagic = magic(of: current),
              let persistedVersion = formatVersion(of: persisted),
              let currentVersion = formatVersion(of: current)
        else { return false }
        return persistedMagic == currentMagic && persistedVersion != currentVersion
    }
}
