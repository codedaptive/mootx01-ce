//! The fixed prefix every provider basis and counts blob starts with:
//!
//!   MAGIC (4 ASCII bytes naming the provider) | FORMAT_VERSION (1 byte) | payload
//!
//! The codec that writes and reads these blobs lives in `corpus-kit-providers`
//! (`basis_codec.rs`); core `corpus-kit` never interprets the payload. Core
//! reads ONLY this five-byte frame, and only to compare a PERSISTED blob
//! against the frame the CURRENT provider writes for the same magic. That
//! comparison is how an estate written by an earlier codec is recognised at
//! open: the persisted basis is not decoded as if it were the current one
//! (the codec would refuse it), and it is not silently served — the slot
//! opens untrained and the ordinary reconcile / upgrade retrain publishes a
//! current basis over it.
//!
//! Swift twin: packages/kits/CorpusKit/Sources/CorpusKit/BasisBlobFrame.swift

/// Bytes in the frame: 4 magic bytes + 1 format-version byte.
pub const LENGTH: usize = 5;

/// The format-version byte of `blob`, or `None` when the blob is too short
/// to carry a frame.
pub fn format_version(blob: &[u8]) -> Option<u8> {
    if blob.len() >= LENGTH {
        Some(blob[4])
    } else {
        None
    }
}

/// The 4 magic bytes of `blob`, or `None` when the blob is too short.
pub fn magic(blob: &[u8]) -> Option<&[u8]> {
    if blob.len() >= LENGTH {
        Some(&blob[..4])
    } else {
        None
    }
}

/// True when `persisted` carries the SAME magic as `current` but a DIFFERENT
/// format version: a blob written by another codec generation for this
/// provider. A blob too short to frame, or one whose magic differs (a keying
/// error, not a version skew), is not "stale" — the decoder reports those as
/// the corruption they are.
pub fn is_stale_version(persisted: &[u8], current: &[u8]) -> bool {
    match (magic(persisted), magic(current), format_version(persisted), format_version(current)) {
        (Some(pm), Some(cm), Some(pv), Some(cv)) => pm == cm && pv != cv,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_magic_other_version_is_stale() {
        assert!(is_stale_version(b"RIB1\x01payload", b"RIB1\x02"));
        assert!(!is_stale_version(b"RIB1\x02payload", b"RIB1\x02"));
    }

    #[test]
    fn other_magic_or_short_blob_is_not_stale() {
        assert!(!is_stale_version(b"PPB1\x01", b"RIB1\x02"), "a keying error is not a version skew");
        assert!(!is_stale_version(b"RIB", b"RIB1\x02"), "too short to frame");
        assert!(!is_stale_version(b"", b"RIB1\x02"));
        assert_eq!(format_version(b"RIB1\x07"), Some(7));
        assert_eq!(format_version(b"RIB1"), None);
    }
}
